import SwiftUI

/// API Tester: method, URL, headers, body in; status, timing, body out.
///
/// Explicitly on-demand. Saved requests are stored but **never** replayed in the
/// background -- there is no "monitor this endpoint" feature, because that would
/// be a background network timer, which is the exact thing this app promises not
/// to have.
@MainActor
final class APITesterModel: ObservableObject {
    struct SavedRequest: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var method: String
        var url: String
        var headers: [String: String]
        var body: String
    }
    private struct Model: Codable { var saved: [SavedRequest] = [] }

    @Published var method = "GET"
    @Published var url = ""
    @Published var headerText = ""      // "Key: Value" per line — faster to type than a grid
    @Published var bodyText = ""
    @Published var saved: [SavedRequest] = []

    @Published private(set) var isRunning = false
    @Published private(set) var status: Int?
    @Published private(set) var elapsedMs: Int?
    @Published private(set) var responseBody = ""
    @Published private(set) var responseHeaders: [String: String] = [:]
    @Published private(set) var errorText: String?
    @Published private(set) var responseBytes = 0

    private let store = JSONStore<Model>(filename: "api-requests.json", debounce: 1.0)
    private var task: Task<Void, Never>?

    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    func load() { saved = (store.load() ?? Model()).saved }
    func cancel() { task?.cancel(); task = nil; isRunning = false }

    func save() {
        guard !url.isEmpty else { return }
        let request = SavedRequest(name: URL(string: url)?.path ?? url,
                                   method: method, url: url,
                                   headers: parsedHeaders(), body: bodyText)
        saved.insert(request, at: 0)
        if saved.count > 30 { saved.removeLast(saved.count - 30) }
        store.save(Model(saved: saved))
    }

    func load(_ request: SavedRequest) {
        method = request.method
        url = request.url
        headerText = request.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        bodyText = request.body
    }

    func remove(_ id: UUID) {
        saved.removeAll { $0.id == id }
        store.save(Model(saved: saved))
    }

    private func parsedHeaders() -> [String: String] {
        var result: [String: String] = [:]
        for line in headerText.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    func send() {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespaces)), target.scheme != nil else {
            errorText = "Enter a full URL including https://"
            return
        }
        cancel()
        isRunning = true
        errorText = nil
        status = nil
        responseBody = ""

        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (key, value) in parsedHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        if !bodyText.isEmpty, method != "GET", method != "HEAD" {
            request.httpBody = Data(bodyText.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        // A fresh ephemeral session per send: no cookie jar, no credential store,
        // no disk cache carrying one test's auth into the next one.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        task = Task { [weak self] in
            let started = Date()
            do {
                let (data, response) = try await session.data(for: request)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedMs = ms
                    self.responseBytes = data.count
                    if let http = response as? HTTPURLResponse {
                        self.status = http.statusCode
                        self.responseHeaders = Dictionary(uniqueKeysWithValues:
                            http.allHeaderFields.compactMap { key, value in
                                guard let k = key as? String else { return nil }
                                return (k, String(describing: value))
                            })
                    }
                    self.responseBody = Self.prettyPrint(data)
                    self.isRunning = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.errorText = error.localizedDescription
                    self?.isRunning = false
                    self?.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                }
            }
        }
    }

    /// Pretty-print JSON when it is JSON; otherwise show the raw text. Large
    /// bodies are truncated so a 50MB response cannot blow up the view.
    private static func prettyPrint(_ data: Data) -> String {
        let limit = 256 * 1024
        let slice = data.count > limit ? data.prefix(limit) : data
        if let object = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: pretty, encoding: .utf8) {
            return text + (data.count > limit ? "\n… truncated" : "")
        }
        let text = String(data: slice, encoding: .utf8) ?? "<\(data.count) bytes of binary>"
        return text + (data.count > limit ? "\n… truncated" : "")
    }
}

struct APITesterTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var model = APITesterModel()
    @State private var pane = 0

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $model.method) {
                    ForEach(APITesterModel.methods, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 88)
                NBTextField(placeholder: "https://api.example.com/v1/things",
                            text: $model.url, monospaced: true) { model.send() }
                Button(model.isRunning ? "…" : "Send") { model.send() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.api), filled: true, compact: true))
                    .disabled(model.isRunning)
                Button {
                    model.save()
                } label: { Image(systemName: "bookmark").font(.system(size: 10)) }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.api), compact: true))
            }
            .padding(.horizontal, 12).padding(.top, 8)

            Picker("", selection: $pane) {
                Text("Headers").tag(0); Text("Body").tag(1)
                Text("Response").tag(2); Text("Saved").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12)

            Group {
                switch pane {
                case 0:
                    editor(text: $model.headerText,
                           placeholder: "Authorization: Bearer …\nAccept: application/json")
                case 1:
                    editor(text: $model.bodyText, placeholder: "{\n  \"key\": \"value\"\n}")
                case 2:
                    responsePane(theme)
                default:
                    savedPane(theme)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.load() }
        .onDisappear { model.cancel() }
    }

    private func editor(text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(themes.theme.secondaryText.opacity(0.55))
                    .padding(.horizontal, 17).padding(.top, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private func responsePane(_ theme: Theme) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                if let status = model.status {
                    Text("\(status)")
                        .font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(statusColor(status).opacity(0.22)))
                        .foregroundStyle(statusColor(status))
                }
                if let ms = model.elapsedMs {
                    Text("\(ms) ms").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                }
                if model.responseBytes > 0 {
                    Text(FileConverter.formatBytes(model.responseBytes))
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if !model.responseBody.isEmpty {
                    Button("Copy") {
                        ClipboardWatcher.shared.suppressNextChange()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.responseBody, forType: .string)
                        NotchArbiter.shared.flash("Response copied", symbol: "doc.on.doc", module: .api)
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.api), compact: true))
                }
            }
            .padding(.horizontal, 12)

            if let error = model.errorText {
                NBEmptyState(symbol: "exclamationmark.triangle", title: "Request failed", subtitle: error)
            } else if model.responseBody.isEmpty {
                NBEmptyState(symbol: "network", title: "No response yet",
                             subtitle: "Nothing is sent until you press Send — saved requests are never replayed in the background.")
            } else {
                ScrollView {
                    Text(model.responseBody)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .foregroundStyle(theme.primaryText)
                }
            }
        }
    }

    private func savedPane(_ theme: Theme) -> some View {
        Group {
            if model.saved.isEmpty {
                NBEmptyState(symbol: "bookmark", title: "No saved requests")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.saved) { request in
                            NBCard(tint: .api, padding: 7) {
                                HStack(spacing: 7) {
                                    Text(request.method)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(theme.tint(.api))
                                        .frame(width: 42, alignment: .leading)
                                    Text(request.url).font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1).foregroundStyle(theme.primaryText)
                                    Spacer()
                                    Button("Load") { model.load(request) }
                                        .buttonStyle(NBButtonStyle(tint: theme.tint(.api), compact: true))
                                    Button {
                                        model.remove(request.id)
                                    } label: { Image(systemName: "trash").font(.system(size: 9)) }
                                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .cyan
        case 400..<500: return .orange
        default: return .red
        }
    }
}
