import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// A piece of context attached to a conversation.
///
/// Context is held on the **conversation**, not on a single message, because
/// that is how people use it: you attach a file and then ask three questions
/// about it. Re-attaching per turn would be the same bytes three times, and
/// forgetting to would make the second question unanswerable.
struct ChatAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case file, screenshot, snippet }

    var id = UUID()
    var kind: Kind
    var name: String
    /// Extracted text, for files and pasted snippets.
    var text: String = ""
    /// Base64 PNG, for screenshots and images.
    var imageData: String = ""
    /// Where it came from, for files.
    var path: String = ""
    var addedAt = Date()

    var isImage: Bool { !imageData.isEmpty }

    /// Roughly how much of the model's budget this will use. Four characters
    /// per token is the usual English approximation; images are billed by area
    /// and this is a deliberate over-estimate so the number never flatters.
    var approximateTokens: Int {
        isImage ? 1_600 : max(1, text.count / 4)
    }

    var sizeNote: String {
        if isImage { return "image" }
        if text.count > 1_000 { return "\(text.count / 1_000)k chars" }
        return "\(text.count) chars"
    }
}

/// One conversation: its messages, its context, and enough metadata to find it
/// again in the history list.
struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = ""
    var messages: [LLMMessage] = []
    var attachments: [ChatAttachment] = []
    var createdAt = Date()
    var updatedAt = Date()

    var isEmpty: Bool { messages.isEmpty && attachments.isEmpty }

    /// The first thing the user said, trimmed to a line.
    ///
    /// Derived rather than asked for: naming a conversation is a chore nobody
    /// does, and an untitled list is a list you cannot search. The user can
    /// still rename one, which is why the stored title wins when it is set.
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let first = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else {
            return "New conversation"
        }
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        return line.count > 46 ? String(line.prefix(46)) + "…" : line
    }
}

/// Conversations, on disk.
///
/// ## Why history is persisted at all
/// A chat panel that forgets everything when you switch tabs is a novelty. The
/// value of having a model in the notch is asking it something, going away,
/// and coming back to what it said -- which requires the conversation to
/// outlive the view, the tab switch and the launch.
///
/// ## Why the store is capped
/// Images are base64 in the same JSON file. A handful of screenshots is a few
/// megabytes, and an uncapped store is a file that grows until the debounced
/// write becomes noticeable. Sixty conversations is months of real use.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    private struct Model: Codable {
        var conversations: [Conversation] = []
        var currentID: UUID?
    }

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentID: UUID?

    private let store = JSONStore<Model>(filename: "chats.json", debounce: 1.2)
    private var isLoading = false

    static let maxConversations = 60

    private init() {}

    func start() {
        isLoading = true
        let model = store.load() ?? Model()
        conversations = model.conversations
        currentID = model.currentID ?? conversations.first?.id
        isLoading = false
        if conversations.isEmpty { newConversation() }
    }

    func flush() { store.saveNow(Model(conversations: conversations, currentID: currentID)) }

    private func persist() {
        guard !isLoading else { return }
        store.save(Model(conversations: conversations, currentID: currentID))
    }

    // MARK: - Current conversation

    var current: Conversation {
        conversations.first { $0.id == currentID } ?? Conversation()
    }

    private var currentIndex: Int? {
        conversations.firstIndex { $0.id == currentID }
    }

    /// Most recently touched first, which is the only ordering a history list
    /// wants -- creation order puts the thing you were just doing at the bottom.
    var ordered: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        currentID = id
        persist()
    }

    /// Starts a new conversation, reusing an existing empty one rather than
    /// stacking blank entries every time the button is pressed.
    @discardableResult
    func newConversation() -> UUID {
        if let existing = conversations.first(where: { $0.isEmpty }) {
            currentID = existing.id
            persist()
            return existing.id
        }
        var conversation = Conversation()
        conversation.updatedAt = Date()
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
        trim()
        persist()
        return conversation.id
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = ordered.first?.id }
        if conversations.isEmpty { newConversation() }
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    private func trim() {
        guard conversations.count > Self.maxConversations else { return }
        // Keep the current one whatever its age, then the most recent.
        let keep = conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maxConversations)
        let keepIDs = Set(keep.map(\.id) + [currentID].compactMap { $0 })
        conversations.removeAll { !keepIDs.contains($0.id) }
    }

    // MARK: - Mutation

    func appendMessage(_ message: LLMMessage) {
        guard let index = currentIndex else { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        persist()
    }

    /// Streaming writes to the last message many times a second, so this
    /// deliberately does **not** persist on every delta -- the debounce would
    /// coalesce most of it, but re-encoding the whole store per token is work
    /// nobody needs. The final save happens when the stream ends.
    func updateLastMessage(_ transform: (inout LLMMessage) -> Void) {
        guard let index = currentIndex,
              !conversations[index].messages.isEmpty else { return }
        transform(&conversations[index].messages[conversations[index].messages.count - 1])
    }

    func dropLastMessageIfEmpty() {
        guard let index = currentIndex,
              conversations[index].messages.last?.text.isEmpty == true else { return }
        conversations[index].messages.removeLast()
        persist()
    }

    func finishStreaming() {
        guard let index = currentIndex else { return }
        conversations[index].updatedAt = Date()
        persist()
    }

    func clearMessages() {
        guard let index = currentIndex else { return }
        conversations[index].messages = []
        conversations[index].updatedAt = Date()
        persist()
    }

    // MARK: - Attachments

    func addAttachment(_ attachment: ChatAttachment) {
        guard let index = currentIndex else { return }
        conversations[index].attachments.append(attachment)
        conversations[index].updatedAt = Date()
        persist()
    }

    func removeAttachment(_ id: UUID) {
        guard let index = currentIndex else { return }
        conversations[index].attachments.removeAll { $0.id == id }
        persist()
    }

    func clearAttachments() {
        guard let index = currentIndex else { return }
        conversations[index].attachments = []
        persist()
    }
}

// MARK: - Bringing things in

/// Reads files and takes screenshots for the chat's context panel.
enum ChatContextLoader {

    /// Text-ish types worth reading. Everything else is refused with a reason
    /// rather than attached as mojibake -- a PDF read as UTF-8 is a page of
    /// replacement characters that costs tokens and teaches the model nothing.
    static let maxCharacters = 120_000

    static func load(url: URL) -> Result<ChatAttachment, NBError> {
        let name = url.lastPathComponent

        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url),
                  let data = pngData(from: image) else {
                return .failure(.message("\(name): could not read that image"))
            }
            return .success(ChatAttachment(kind: .file, name: name,
                                           imageData: data.base64EncodedString(),
                                           path: url.path))
        }

        guard let data = try? Data(contentsOf: url) else {
            return .failure(.message("\(name): could not be read"))
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return .failure(.message("\(name) is not text. Attach a screenshot of it instead."))
        }

        // Truncated at the head rather than the tail: the top of a file is its
        // imports, its headers, its front matter. The end is usually where the
        // thing you are asking about lives.
        let trimmed = text.count > maxCharacters
            ? "…(truncated, showing the last \(maxCharacters) characters)…\n"
                + String(text.suffix(maxCharacters))
            : text

        return .success(ChatAttachment(kind: .file, name: name, text: trimmed, path: url.path))
    }

    /// Interactive screen capture -- the same crosshair as ⇧⌘4.
    ///
    /// Shells out to `/usr/sbin/screencapture` deliberately, as the documented
    /// exception to this project's no-subprocess rule. The alternative is
    /// ScreenCaptureKit plus an entire selection UI: a full-screen overlay
    /// window, a drag-rectangle, escape handling, multi-display coordinates.
    /// That is a feature of its own to reimplement something every Mac user
    /// already has muscle memory for, and it would additionally require the
    /// screen-recording permission that this path does not.
    static func captureScreenshot(completion: @escaping (Result<ChatAttachment, NBError>) -> Void) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchscotch-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -r no window shadow, -o no window decoration.
        process.arguments = ["-i", "-r", "-o", destination.path]

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: destination) }
                // Cancelling the capture with escape leaves no file, which is
                // not an error -- the user changed their mind.
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    completion(.failure(.message("")))
                    return
                }
                guard let image = NSImage(contentsOf: destination),
                      let data = pngData(from: image) else {
                    completion(.failure(.message("The screenshot could not be read back")))
                    return
                }
                completion(.success(ChatAttachment(
                    kind: .screenshot,
                    name: "Screenshot \(Date().formatted(date: .omitted, time: .standard))",
                    imageData: data.base64EncodedString())))
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(.message("Could not start screencapture: \(error.localizedDescription)")))
        }
    }

    /// Downscales before encoding.
    ///
    /// A retina screenshot of a 5K display is 5120px wide, which is several
    /// megabytes of base64 and more image tokens than the answer is worth. Both
    /// vendors downscale above ~1568px on the long edge anyway, so sending more
    /// is paying to transmit pixels that get thrown away.
    static func pngData(from image: NSImage, maxPixels: CGFloat = 1_568) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        let longest = max(width, height)

        let cgImage: CGImage
        if longest > maxPixels {
            let scale = maxPixels / longest
            let targetWidth = Int(width * scale), targetHeight = Int(height * scale)
            guard let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let scaled = context.makeImage() else { return nil }
            cgImage = scaled
        } else {
            cgImage = source
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
