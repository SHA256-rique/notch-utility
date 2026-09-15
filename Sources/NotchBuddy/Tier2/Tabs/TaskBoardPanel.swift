import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The kanban panel that shares the Snippets tab with clipboard history.
///
/// Laid out as a side panel rather than a sub-view behind a segmented control,
/// because the one interaction that justifies pairing these two features --
/// turning a clipboard entry into a task -- only works if both are on screen at
/// once. A toggle would put them one click apart and the button would have
/// nowhere sensible to point.
struct TaskBoardPanel: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var board = TaskBoard.shared
    @State private var draft = ""
    @State private var draftLane: TaskLane = .todo
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var dragging: UUID?
    @State private var dropLane: TaskLane?

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                NBSectionHeader(title: "Tasks", trailing: "\(board.openCount) open")
            }

            HStack(spacing: 5) {
                NBTextField(placeholder: "Add a task…", text: $draft) { commitDraft() }
                Button {
                    commitDraft()
                } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.snippets), filled: true, compact: true))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(TaskLane.allCases) { lane in
                        laneView(lane, theme: theme)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Lane

    private func laneView(_ lane: TaskLane, theme: Theme) -> some View {
        let items = board.tasks(in: lane)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: lane.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(tint(lane, theme))
                Text(lane.title.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(theme.secondaryText)
                Text("\(items.count)")
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(theme.secondaryText.opacity(0.7))
                Spacer()
                if lane == .done && !items.isEmpty {
                    Button("Clear") { board.clearDone() }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                }
            }

            VStack(spacing: 3) {
                if items.isEmpty {
                    Text(lane == .todo ? "Nothing queued." : "—")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
                ForEach(items) { task in
                    card(task, theme: theme)
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dropLane == lane ? tint(lane, theme).opacity(0.10) : Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(dropLane == lane ? tint(lane, theme).opacity(0.6) : Color.clear,
                                    lineWidth: 1)
                    )
            )
            // Dropping on the lane's empty space moves the task to the end of
            // that lane; dropping on a card positions it precisely. Both are
            // needed -- without the lane target you cannot move into an empty
            // column at all.
            .onDrop(of: [.text], delegate: LaneDropDelegate(
                lane: lane, dragging: $dragging, dropLane: $dropLane))
        }
        .animation(Motion.tabSwitch, value: dropLane)
    }

    private struct LaneDropDelegate: DropDelegate {
        let lane: TaskLane
        @Binding var dragging: UUID?
        @Binding var dropLane: TaskLane?

        func dropEntered(info: DropInfo) { dropLane = lane }
        func dropExited(info: DropInfo) { if dropLane == lane { dropLane = nil } }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            defer { dragging = nil; dropLane = nil }
            guard let id = dragging else { return false }
            TaskBoard.shared.move(id, to: lane)
            return true
        }
    }

    // MARK: - Card

    private func card(_ task: BoardTask, theme: Theme) -> some View {
        let laneTint = tint(task.lane, theme)
        return HStack(alignment: .top, spacing: 6) {
            // The checkbox advances one lane rather than jumping to done, so a
            // single click walks todo → doing → done and the "Doing" column is
            // reachable without ever dragging anything.
            Button {
                withAnimation(Motion.sheet) { board.advance(task.id) }
            } label: {
                Image(systemName: task.lane.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(laneTint)
            }
            .buttonStyle(.plain)
            .help("Move to \(task.lane.next.title)")

            if editing == task.id {
                NBTextField(placeholder: "Task", text: $editText) {
                    board.update(task.id, text: editText)
                    editing = nil
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.text)
                        .font(.system(size: 10))
                        .foregroundStyle(task.lane == .done ? theme.secondaryText : theme.primaryText)
                        .strikethrough(task.lane == .done, color: theme.secondaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if task.sourceSnippetID != nil {
                        Label("from clipboard", systemImage: "doc.on.clipboard")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            Button {
                board.remove(task.id)
            } label: { Image(systemName: "xmark").font(.system(size: 8)) }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText.opacity(0.7))
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(alignment: .leading) {
                    Capsule().fill(laneTint.opacity(0.7)).frame(width: 2)
                }
        )
        .opacity(dragging == task.id ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editText = task.text
            editing = task.id
        }
        .onDrag {
            dragging = task.id
            return NSItemProvider(object: task.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: CardDropDelegate(
            target: task.id, dragging: $dragging, dropLane: $dropLane))
        .contextMenu {
            Button("Copy text") { copy(task) }
            Button("Save as snippet") {
                SnippetStore.shared.add(text: task.text, title: "", tag: "task")
            }
            Divider()
            ForEach(TaskLane.allCases) { lane in
                Button("Move to \(lane.title)") { board.move(task.id, to: lane) }
                    .disabled(lane == task.lane)
            }
            Divider()
            Button("Delete", role: .destructive) { board.remove(task.id) }
        }
    }

    private struct CardDropDelegate: DropDelegate {
        let target: UUID
        @Binding var dragging: UUID?
        @Binding var dropLane: TaskLane?

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            defer { dragging = nil; dropLane = nil }
            guard let id = dragging, id != target else { return false }
            TaskBoard.shared.reorder(id, before: target)
            return true
        }
    }

    // MARK: - Helpers

    private func tint(_ lane: TaskLane, _ theme: Theme) -> Color {
        switch lane {
        case .todo:  return theme.secondaryText
        case .doing: return theme.tint(.time)
        case .done:  return .green
        }
    }

    private func commitDraft() {
        board.add(draft, lane: draftLane)
        draft = ""
    }

    private func copy(_ task: BoardTask) {
        ClipboardWatcher.shared.suppressNextChange()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(task.text, forType: .string)
        NotchArbiter.shared.flash("Copied", symbol: "doc.on.doc.fill", module: .snippets)
    }
}
