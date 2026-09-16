import Foundation
import Network
import CryptoKit
import AppKit

/// OAuth 2.0 for installed apps, with PKCE and a loopback redirect.
///
/// ## Why this flow and not the others
/// Google retired the `urn:ietf:wg:oauth:2.0:oob` out-of-band flow (the one that
/// shows you a code to paste) and does not permit the implicit flow for new
/// clients. For a native desktop app the supported path is: open the system
/// browser, have Google redirect to `http://127.0.0.1:<port>`, and catch that
/// redirect on a listener we own. Google explicitly allows loopback redirects on
/// *any* port, which is what lets this use an ephemeral one instead of squatting
/// on a fixed port that might already be taken.
///
/// ## Why PKCE matters even with a client secret
/// A "client secret" shipped inside a desktop app is not a secret -- anyone can
/// read it out of the binary. Google knows this and documents installed-app
/// secrets as non-confidential. PKCE is what actually secures the exchange: the
/// authorization code is only redeemable by whoever holds the verifier, which
/// never leaves this process. A malicious local app that races us to the
/// loopback port still cannot exchange the code it intercepts.
///
/// ## Why the browser and not an embedded web view
/// An embedded view means the app can see the user's Google password. Even if it
/// does not look, the user cannot verify that, and Google blocks embedded
/// user-agents for exactly this reason. The system browser also means an
/// existing Google session is reused, so most sign-ins are two clicks.
@MainActor
final class GoogleOAuth {

    struct Tokens {
        var accessToken: String
        var expiresAt: Date
        var refreshToken: String?
    }

    enum OAuthError: LocalizedError {
        case notConfigured
        case listenerFailed(String)
        case denied(String)
        case exchangeFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notConfigured:          return "Add a Google OAuth client ID in Settings first."
            case .listenerFailed(let m):  return "Could not open a local listener: \(m)"
            case .denied(let m):          return "Google declined: \(m)"
            case .exchangeFailed(let m):  return "Token exchange failed: \(m)"
            case .cancelled:              return "Sign-in cancelled."
            }
        }
    }

    static let refreshTokenAccount = "google.calendar.refresh"
    /// Read-only. This app displays events; it has no feature that writes one,
    /// and asking for write access we do not use would be indefensible on a
    /// consent screen the user is reading.
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"

    private static let authorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var pending: CheckedContinuation<String, Error>?

    // MARK: - Sign in

    /// Runs the full flow and returns tokens. The refresh token is the caller's
    /// to store; this type deliberately does not touch Keychain so the flow can
    /// be reasoned about without also reasoning about persistence.
    func signIn(clientID: String, clientSecret: String) async throws -> Tokens {
        guard !clientID.isEmpty else { throw OAuthError.notConfigured }

        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        let state = Self.randomVerifier()

        let port = try startListener()
        defer { stopListener() }

        let redirect = "http://127.0.0.1:\(port)"
        var components = URLComponents(string: Self.authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Without these two Google returns a refresh token only on the very
            // first authorisation ever, so a user who revokes and re-links gets
            // an access token that dies in an hour and never comes back.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components.url else { throw OAuthError.notConfigured }

        NSWorkspace.shared.open(url)

        let code = try await waitForCode(expectedState: state)
        return try await exchange(code: code, verifier: verifier, redirect: redirect,
                                  clientID: clientID, clientSecret: clientSecret)
    }

    /// Trades a stored refresh token for a fresh access token. No browser, no
    /// listener -- this is the path taken on every launch after the first.
    static func refresh(refreshToken: String, clientID: String, clientSecret: String) async throws -> Tokens {
        var fields = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        let payload = try await post(fields)
        guard let accessToken = payload["access_token"] as? String else {
            throw OAuthError.exchangeFailed(Self.errorText(payload))
        }
        let expiresIn = (payload["expires_in"] as? Double) ?? 3600
        // Google does not reissue the refresh token on a refresh, so the caller
        // keeps the one it already has.
        return Tokens(accessToken: accessToken,
                      expiresAt: Date().addingTimeInterval(expiresIn - 60),
                      refreshToken: nil)
    }

    // MARK: - Listener

    private func startListener() throws -> UInt16 {
        do {
            let parameters = NWParameters.tcp
            // Loopback only. Binding to every interface would let anything on
            // the network reach the redirect catcher.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handle(connection) }
            }
            listener.start(queue: .main)

            // NWListener assigns the port asynchronously; spin briefly rather
            // than making the whole API async just for this.
            var attempts = 0
            while listener.port == nil || listener.port?.rawValue == 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                attempts += 1
                if attempts > 100 { throw OAuthError.listenerFailed("no port assigned") }
            }
            guard let port = listener.port?.rawValue else {
                throw OAuthError.listenerFailed("no port assigned")
            }
            return port
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.listenerFailed(error.localizedDescription)
        }
    }

    private func stopListener() {
        for connection in connections { connection.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func waitForCode(expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.pending = continuation
            self.expectedState = expectedState
            // Five minutes is long enough to find the right Google account and
            // read a consent screen, and short enough that an abandoned flow
            // does not leave a socket open all afternoon.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                self.finish(.failure(OAuthError.cancelled))
            }
        }
    }

    private var expectedState: String?

    private func finish(_ result: Result<String, Error>) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
                self.process(request: request, on: connection)
            }
        }
    }

    /// Parses the request line of a minimal HTTP/1.1 request. This is not a web
    /// server -- it answers exactly one request, from one origin, and then shuts
    /// down. Anything it does not recognise gets a 400 and is forgotten.
    private func process(request: String, on connection: NWConnection) {
        guard let line = request.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            respond(connection, status: "400 Bad Request", body: "Bad request")
            return
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            respond(connection, status: "200 OK", body: Self.page(
                title: "Sign-in declined",
                detail: "You can close this tab and try again from NotchScotch."))
            finish(.failure(OAuthError.denied(error)))
            return
        }

        // The state check is what stops an attacker's authorization code being
        // planted into this session.
        guard let state = value("state"), state == expectedState else {
            respond(connection, status: "400 Bad Request", body: "State mismatch")
            finish(.failure(OAuthError.denied("state mismatch")))
            return
        }

        guard let code = value("code") else {
            respond(connection, status: "400 Bad Request", body: "No code")
            return
        }

        respond(connection, status: "200 OK", body: Self.page(
            title: "NotchScotch is connected",
            detail: "Your Google Calendar is linked. You can close this tab."))
        finish(.success(code))
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(title: String, detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,system-ui,sans-serif;background:#111;color:#eee;\
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
        <div style="text-align:center"><h2 style="font-weight:600">\(title)</h2>
        <p style="opacity:.7">\(detail)</p></div></body></html>
        """
    }

    // MARK: - Token exchange

    private func exchange(code: String, verifier: String, redirect: String,
                          clientID: String, clientSecret: String) async throws -> Tokens {
        var fields = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }

        let payload = try await Self.post(fields)
        guard let accessToken = payload["access_token"] as? String else {
            throw OAuthError.exchangeFailed(Self.errorText(payload))
        }
        let expiresIn = (payload["expires_in"] as? Double) ?? 3600
        return Tokens(accessToken: accessToken,
                      expiresAt: Date().addingTimeInterval(expiresIn - 60),
                      refreshToken: payload["refresh_token"] as? String)
    }

    private static func post(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { key, value in
            "\(key)=\(Self.formEncode(value))"
        }.joined(separator: "&").utf8)
        request.timeoutInterval = 25

        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func errorText(_ payload: [String: Any]) -> String {
        let code = payload["error"] as? String ?? "unknown"
        let description = payload["error_description"] as? String
        return description.map { "\(code): \($0)" } ?? code
    }

    // MARK: - PKCE

    /// 64 random bytes, base64url-encoded. Comfortably inside the spec's
    /// 43-128 character range and generated from the system CSPRNG rather than
    /// from `Int.random`, which is not one.
    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
