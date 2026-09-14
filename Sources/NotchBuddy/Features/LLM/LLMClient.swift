import Foundation

/// One request/response path for every LLM feature in the app.
///
/// The AI Chat tab and the selection-aware rewrite/translate feature are
/// architecturally separate -- different triggers, different UI, different
/// lifetimes -- but they must not each own a copy of the networking, the SSE
/// parsing and the provider quirks. Everything vendor-specific is confined to
/// `buildRequest` and `parseStreamChunk`; both callers see the same
/// `AsyncThrowingStream<String, Error>` of text deltas.
enum LLMError: LocalizedError {
    case noKey(LLMProvider)
    case http(Int, String)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noKey(let provider):
            return "No API key set for \(provider.displayName). Add one in Settings."
        case .http(let code, let body):
            return "Provider returned \(code): \(body.prefix(200))"
        case .transport(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

struct LLMMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, system }
    let id = UUID()
    var role: Role
    var text: String
}

struct LLMClient {

    // MARK: - Public

    /// Streams text deltas. Cancelling the consuming Task cancels the request.
    static func stream(messages: [LLMMessage],
                       system: String? = nil,
                       maxTokens: Int = 1500) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let settings = Settings.shared.data
                    let provider = settings.llmProvider
                    let request = try buildRequest(provider: provider,
                                                   model: settings.llmModel,
                                                   endpointOverride: settings.llmEndpointOverride,
                                                   messages: messages,
                                                   system: system,
                                                   maxTokens: maxTokens,
                                                   stream: true)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.transport("No HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain enough of the error body to be useful without
                        // buffering a huge response.
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 600 { break }
                        }
                        throw LLMError.http(http.statusCode, body)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let delta = parseStreamChunk(line, provider: provider), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience, used by the selection-assist popover where the
    /// result is short and appears all at once.
    static func complete(messages: [LLMMessage], system: String? = nil, maxTokens: Int = 700) async throws -> String {
        var output = ""
        for try await delta in stream(messages: messages, system: system, maxTokens: maxTokens) {
            output += delta
        }
        return output
    }

    static func hasCredentials(for provider: LLMProvider) -> Bool {
        !provider.needsKey || Keychain.has(provider.keychainAccount)
    }

    // MARK: - Request building

    private static func buildRequest(provider: LLMProvider, model: String,
                                     endpointOverride: String,
                                     messages: [LLMMessage], system: String?,
                                     maxTokens: Int, stream: Bool) throws -> URLRequest {
        let endpoint = endpointOverride.isEmpty ? provider.defaultEndpoint : endpointOverride
        guard let url = URL(string: endpoint) else { throw LLMError.transport("Bad endpoint URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // The key is pulled from the Keychain here, at the moment of use, and is
        // never held in a property or written to the settings file.
        let key = Keychain.get(provider.keychainAccount)
        if provider.needsKey {
            guard let key, !key.isEmpty else { throw LLMError.noKey(provider) }
        }

        let body: [String: Any]
        switch provider {
        case .anthropic:
            request.setValue(key!, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var payload: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "stream": stream,
                // Anthropic takes the system prompt as a top-level field rather
                // than as a message with role "system".
                "messages": messages.filter { $0.role != .system }.map {
                    ["role": $0.role.rawValue, "content": $0.text]
                }
            ]
            if let system { payload["system"] = system }
            body = payload

        case .openai:
            request.setValue("Bearer \(key!)", forHTTPHeaderField: "Authorization")
            var chat: [[String: Any]] = []
            if let system { chat.append(["role": "system", "content": system]) }
            chat += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
            body = ["model": model, "max_tokens": maxTokens, "stream": stream, "messages": chat]

        case .ollama:
            // Local, keyless. Same message shape as OpenAI, different streaming
            // format (newline-delimited JSON rather than SSE).
            var chat: [[String: Any]] = []
            if let system { chat.append(["role": "system", "content": system]) }
            chat += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
            body = ["model": model, "stream": stream, "messages": chat]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Stream parsing

    /// Returns the text delta in one streamed line, or nil for keep-alives,
    /// metadata events and terminators.
    private static func parseStreamChunk(_ line: String, provider: LLMProvider) -> String? {
        switch provider {
        case .anthropic, .openai:
            // Both speak server-sent events: "data: {json}".
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            if provider == .anthropic {
                // Only content_block_delta carries text; message_start,
                // ping and message_delta do not.
                guard (json["type"] as? String) == "content_block_delta",
                      let delta = json["delta"] as? [String: Any] else { return nil }
                return delta["text"] as? String
            } else {
                guard let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { return nil }
                return delta["content"] as? String
            }

        case .ollama:
            // Newline-delimited JSON, one object per line, no "data:" prefix.
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }
}
