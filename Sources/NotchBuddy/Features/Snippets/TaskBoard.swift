import Foundation
import Combine

/// Where a task sits on the board.
///
/// Three columns, fixed. User-definable columns would mean a column editor, a
/// migration story for renamed columns, and a board that no longer fits beside
/// the clipboard list at panel width. The value of a notch-sized board is that
/// it is glanceable; the moment it needs horizontal scrolling it has stopped
/// being that and the user should be in a real project tool.
enum TaskLane: String, Codable, CaseIterable, Identifiable {
    case todo, doing, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo:  return "To do"
        case .doing: return "Doing"
        case .done:  return "Done"
        }
    }

    var symbol: String {
        switch self {
        case .todo:  return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .done:  return "checkmark.circle.fill"
        }
    }

    var next: TaskLane {
        switch self {
        case .todo:  return .doing
        case .doing: return .done
        case .done:  return .todo
        }
    }
}

struct BoardTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var lane: TaskLane = .todo
    var createdAt = Date()
    var completedAt: Date?
    /// Manual position within a lane. Reordering writes this rather than
    /// relying on array order, so a task moving between lanes cannot land in an
    /// arbitrary slot.
    var order: Double = 0
    /// Set when the task was created from a clipboard entry, so the board can
    /// show where it came from.
    var sourceSnippetID: UUID?
}

/// The task board that lives beside clipboard history.
///
/// ## Why it shares a tab with the clipboard rather than having its own
/// The two are the same gesture at different time scales: something crossed
/// your attention and you want it back later. In practice you copy an error
/// message and want a task about it; you read a task and want to copy its text.
/// Putting them side by side makes "turn this clipboard entry into a task" a
/// single button instead of a cross-tab round trip -- which is the one
/// interaction that justifies the pairing.
///
/// Local JSON, like everything else here. No sync, no account, no server.
@MainActor
final class TaskBoard: ObservableObject {
    static let shared = TaskBoard()

    private struct Model: Codable { var tasks: [BoardTask] = [] }

    @Published private(set) var tasks: [BoardTask] = []

    private let store = JSONStore<Model>(filename: "tasks.json", debounce: 0.8)
    private var isLoading = false

    private init() {}

    func start() {
        isLoading = true
        tasks = (store.load() ?? Model()).tasks
        isLoading = false
    }

    func flush() { store.saveNow(Model(tasks: tasks)) }

    private func persist() {
        guard !isLoading else { return }
        store.save(Model(tasks: tasks))
    }

    // MARK: - Queries

    func tasks(in lane: TaskLane) -> [BoardTask] {
        tasks.filter { $0.lane == lane }.sorted { $0.order < $1.order }
    }

    var openCount: Int { tasks.filter { $0.lane != .done }.count }

    // MARK: - Mutation

    @discardableResult
    func add(_ text: String, lane: TaskLane = .todo, from snippet: UUID? = nil) -> BoardTask? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // New tasks go to the top of their lane: the thing you just thought of
        // is the thing you are most likely to act on.
        let task = BoardTask(text: trimmed, lane: lane,
                             order: (tasks(in: lane).first?.order ?? 0) - 1,
                             sourceSnippetID: snippet)
        tasks.append(task)
        persist()
        return task
    }

    func update(_ id: UUID, text: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            tasks.remove(at: index)
        } else {
            tasks[index].text = trimmed
        }
        persist()
    }

    func move(_ id: UUID, to lane: TaskLane) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].lane != lane else { return }
        tasks[index].lane = lane
        tasks[index].order = (tasks(in: lane).first?.order ?? 0) - 1
        tasks[index].completedAt = lane == .done ? Date() : nil
        persist()
        if lane == .done {
            NotchArbiter.shared.flash("Done", symbol: "checkmark.circle.fill",
                                      module: .snippets, detail: tasks[index].text)
        }
    }

    /// Reorders within a lane by taking the midpoint between the neighbours of
    /// the drop position. Fractional ordering means a move touches one row
    /// rather than renumbering the whole lane.
    func reorder(_ id: UUID, before target: UUID) {
        guard let moving = tasks.firstIndex(where: { $0.id == id }),
              let targetTask = tasks.first(where: { $0.id == target }) else { return }
        let lane = targetTask.lane
        let ordered = tasks(in: lane).filter { $0.id != id }
        guard let position = ordered.firstIndex(where: { $0.id == target }) else { return }
        let above = position > 0 ? ordered[position - 1].order : targetTask.order - 2
        tasks[moving].lane = lane
        tasks[moving].order = (above + targetTask.order) / 2
        if lane != .done { tasks[moving].completedAt = nil }
        persist()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    func clearDone() {
        tasks.removeAll { $0.lane == .done }
        persist()
    }

    /// Advances a task one lane. The single-click path, for when dragging is
    /// more precision than the action deserves.
    func advance(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        move(id, to: task.lane.next)
    }
}
