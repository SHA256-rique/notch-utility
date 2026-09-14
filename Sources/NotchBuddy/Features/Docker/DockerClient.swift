import Foundation

/// Minimal Docker Engine API client speaking HTTP/1.1 over the unix socket.
///
/// ## Why not shell out to `docker ps`
/// Same reason as everywhere else in this codebase, plus two Docker-specific
/// ones:
///   * The `docker` CLI may not be on `PATH` for a GUI app. GUI processes do not
///     inherit the shell's environment, so a Docker Desktop install that works
///     perfectly in Terminal is invisible to an app that spawns `/usr/bin/env
///     docker`. Talking to the socket directly sidesteps the whole class of
///     "works in my terminal" bug reports.
///   * `docker ps` output is formatted for humans and its columns shift. The
///     Engine API returns JSON with a documented, versioned schema.
///
/// ## Why a hand-rolled socket instead of URLSession
/// `URLSession` cannot open an AF_UNIX socket. `NSURLSessionConfiguration` has
/// no unix-domain transport. The options were: a dependency, or ~100 lines of
/// `connect`/`write`/`read` plus a header split. Given the request is a single
/// GET with no auth, no redirects and no chunk negotiation beyond one case, the
/// socket code is smaller and more auditable than the dependency would be.
///
/// Everything here is on-demand: `list()` is called when the tab opens and when
/// the user hits refresh. There is no background poll of the daemon.
enum DockerClient {

    struct Container: Identifiable, Equatable {
        let id: String
        let name: String
        let image: String
        let state: String       // running | exited | paused | created | restarting
        let status: String      // "Up 3 hours"
        let ports: [String]
        var isRunning: Bool { state == "running" }
    }

    enum DockerError: LocalizedError {
        case socketUnavailable
        case connectionFailed(String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .socketUnavailable:
                return "Docker socket not found. Is Docker Desktop (or Colima/OrbStack) running?"
            case .connectionFailed(let detail): return "Couldn't reach the Docker daemon: \(detail)"
            case .badResponse(let detail): return "Unexpected response from Docker: \(detail)"
            }
        }
    }

    /// Candidate socket paths, in the order they are most likely to be correct.
    /// Docker Desktop moved to a per-user socket some versions ago but still
    /// symlinks the classic path; Colima and OrbStack each use their own.
    private static var socketCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.docker/run/docker.sock",      // Docker Desktop (modern)
            "/var/run/docker.sock",                 // classic / symlink
            "\(home)/.colima/default/docker.sock",  // Colima
            "\(home)/.orbstack/run/docker.sock"     // OrbStack
        ]
    }

    static func socketPath() -> String? {
        socketCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static var isAvailable: Bool { socketPath() != nil }

    /// `GET /containers/json?all=1`
    static func list() async throws -> [Container] {
        guard let path = socketPath() else { throw DockerError.socketUnavailable }
        let body = try await get("/v1.43/containers/json?all=1", socket: path)
        guard let array = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            throw DockerError.badResponse("expected a JSON array")
        }
        return array.map { entry in
            let names = (entry["Names"] as? [String] ?? [])
                .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            let ports: [String] = (entry["Ports"] as? [[String: Any]] ?? []).compactMap { port in
                guard let privatePort = port["PrivatePort"] as? Int else { return nil }
                if let publicPort = port["PublicPort"] as? Int {
                    return "\(publicPort)→\(privatePort)"
                }
                return "\(privatePort)"
            }
            return Container(
                id: String((entry["Id"] as? String ?? "").prefix(12)),
                name: names.first ?? "(unnamed)",
                image: entry["Image"] as? String ?? "",
                state: entry["State"] as? String ?? "unknown",
                status: entry["Status"] as? String ?? "",
                // Dedupe: Docker reports IPv4 and IPv6 bindings separately and
                // showing "8080→80  8080→80" looks like a bug.
                ports: Array(Set(ports)).sorted())
        }
    }

    // MARK: - Raw HTTP over AF_UNIX

    private static func get(_ path: String, socket socketPath: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try performGet(path, socketPath: socketPath)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performGet(_ path: String, socketPath: String) throws -> Data {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerError.connectionFailed("socket() failed") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path is a fixed 104-byte C array; a longer path cannot be
        // represented and must be rejected rather than silently truncated.
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DockerError.connectionFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, size)
            }
        }
        guard connected == 0 else {
            throw DockerError.connectionFailed(String(cString: strerror(errno)))
        }

        // A read timeout matters: a wedged daemon would otherwise hang the
        // dispatch worker indefinitely.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // `Connection: close` lets us read to EOF instead of implementing
        // keep-alive framing.
        let request = "GET \(path) HTTP/1.1\r\nHost: docker\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
        let requestBytes = Array(request.utf8)
        var written = 0
        while written < requestBytes.count {
            let n = requestBytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: written), requestBytes.count - written)
            }
            guard n > 0 else { throw DockerError.connectionFailed("write failed") }
            written += n
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 { response.append(contentsOf: buffer[0..<n]) }
            else if n == 0 { break }
            else { throw DockerError.connectionFailed(String(cString: strerror(errno))) }
        }

        return try parseHTTP(response)
    }

    /// Splits headers from body and, if the daemon used chunked transfer
    /// encoding, de-chunks it. Docker does use chunked for `/containers/json`,
    /// so this branch is load-bearing, not defensive.
    private static func parseHTTP(_ raw: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw DockerError.badResponse("no header terminator")
        }
        let headerText = String(decoding: raw[raw.startIndex..<range.lowerBound], as: UTF8.self)
        var body = raw[range.upperBound...]

        guard let statusLine = headerText.split(separator: "\r\n").first,
              let code = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw DockerError.badResponse("malformed status line")
        }
        guard (200..<300).contains(code) else {
            throw DockerError.badResponse("HTTP \(code)")
        }

        if headerText.lowercased().contains("transfer-encoding: chunked") {
            var decoded = Data()
            var cursor = body.startIndex
            while cursor < body.endIndex {
                guard let lineEnd = body[cursor...].range(of: Data("\r\n".utf8)) else { break }
                let sizeText = String(decoding: body[cursor..<lineEnd.lowerBound], as: UTF8.self)
                    .split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
                if size == 0 { break }
                let chunkStart = lineEnd.upperBound
                let chunkEnd = body.index(chunkStart, offsetBy: size, limitedBy: body.endIndex) ?? body.endIndex
                decoded.append(body[chunkStart..<chunkEnd])
                // Skip the CRLF that terminates each chunk.
                cursor = body.index(chunkEnd, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
            }
            body = decoded[decoded.startIndex...]
        }
        return Data(body)
    }
}
