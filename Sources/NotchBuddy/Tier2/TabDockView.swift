import SwiftUI
import UniformTypeIdentifiers

/// The dock of tab icons along the panel's header.
///
/// Three things it has to do that a plain `HStack` of buttons does not:
///
///  1. **Reorder by drag.** The order is the user's, persisted in
///     `Settings.data.enabledTabs`. Built-ins and custom tabs share one dock, so
///     a dragged item is addressed by an `ActiveTab`, not by an index into one
///     of two arrays.
///  2. **Add.** The "+" surfaces the config-driven custom-tab picker and the
///     list of built-ins the user has hidden, because "add a tab" means both of
///     those and the user does not think of them as different operations.
///  3. **Stay out of the way.** It is chrome on a 680pt panel that also has to
///     fit a pin button, a close button and any live persistent claims, so it
///     scrolls horizontally rather than compressing.
struct TabDockView: View {
    @EnvironmentObject private var controller: NotchPanelController
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings

    @State private var dragging: ActiveTab?
    @State private var dropTarget: ActiveTab?
    @State private var showAdd = false

    var body: some View {
        let theme = themes.theme
        HStack(spacing: 3) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(items, id: \.self) { item in
                        button(for: item, theme: theme)
                    }
                }
                .padding(.vertical, 1)
            }

            Button {
                showAdd.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(theme.secondaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .foregroundStyle(theme.panelStroke)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Add a tab")
            .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                AddTabPopover(isPresented: $showAdd)
                    .environmentObject(themes)
                    .environmentObject(settings)
                    .environmentObject(controller)
            }
        }
    }

    /// Built-ins in the user's order, then custom tabs. One flat list so the
    /// drop delegate does not need to know which kind it is moving.
    private var items: [ActiveTab] {
        settings.data.enabledTabs.compactMap(TabID.init(rawValue:)).map(ActiveTab.builtin)
            + settings.data.customTabs.map { ActiveTab.custom($0.id) }
    }

    @ViewBuilder
    private func button(for item: ActiveTab, theme: Theme) -> some View {
        let info = describe(item)
        let isActive = controller.activeTab == item
        Button {
            controller.openTab(item)
        } label: {
            Image(systemName: info.symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(isActive ? info.tint : theme.secondaryText)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? info.tint.opacity(0.18) : .clear)
                )
                .themeGlow(info.tint, radius: isActive ? theme.glowRadius(5) : 0)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(info.title)
        .opacity(dragging == item ? 0.3 : 1)
        .overlay(alignment: .leading) {
            if dropTarget == item, dragging != item {
                Capsule().fill(info.tint).frame(width: 2)
                    .offset(x: -2)
                    .transition(.opacity)
            }
        }
        .onDrag {
            dragging = item
            return NSItemProvider(object: identifier(item) as NSString)
        }
        .onDrop(of: [.text], delegate: DockDropDelegate(
            target: item, dragging: $dragging, dropTarget: $dropTarget, move: move))
        .contextMenu {
            if case .builtin(let id) = item, id != .settings {
                Button("Hide \(id.title)") {
                    settings.data.enabledTabs.removeAll { $0 == id.rawValue }
                    if controller.activeTab == item { controller.openTab(.builtin(.home)) }
                }
            }
            if case .custom(let uuid) = item {
                Button("Remove tab", role: .destructive) {
                    settings.data.customTabs.removeAll { $0.id == uuid }
                    if controller.activeTab == item { controller.openTab(.builtin(.home)) }
                }
            }
        }
        .animation(Motion.tabSwitch, value: dropTarget)
        .animation(Motion.tabSwitch, value: isActive)
    }

    // MARK: - Reordering

    /// Moves `source` to `target`'s position.
    ///
    /// Built-ins and custom tabs are stored in two different arrays, so a drag
    /// that would interleave them (a custom tab dropped between two built-ins)
    /// cannot be represented. Rather than silently doing nothing, such a move
    /// reorders within whichever array the source belongs to, clamped to the
    /// nearest end -- the tab goes somewhere sensible and the gesture is never
    /// a no-op the user has to guess about.
    private func move(_ source: ActiveTab, before target: ActiveTab) {
        guard source != target else { return }
        switch (source, target) {
        case (.builtin(let from), .builtin(let to)):
            var order = settings.data.enabledTabs
            guard let fromIndex = order.firstIndex(of: from.rawValue),
                  let toIndex = order.firstIndex(of: to.rawValue) else { return }
            order.remove(at: fromIndex)
            order.insert(from.rawValue, at: toIndex)
            withAnimation(Motion.tabSwitch) { settings.data.enabledTabs = order }

        case (.custom(let from), .custom(let to)):
            var tabs = settings.data.customTabs
            guard let fromIndex = tabs.firstIndex(where: { $0.id == from }),
                  let toIndex = tabs.firstIndex(where: { $0.id == to }) else { return }
            let moving = tabs.remove(at: fromIndex)
            tabs.insert(moving, at: toIndex)
            withAnimation(Motion.tabSwitch) { settings.data.customTabs = tabs }

        case (.builtin(let from), .custom):
            // Dragged past the end of the built-ins: put it last among them.
            var order = settings.data.enabledTabs
            guard let fromIndex = order.firstIndex(of: from.rawValue) else { return }
            order.remove(at: fromIndex)
            order.append(from.rawValue)
            withAnimation(Motion.tabSwitch) { settings.data.enabledTabs = order }

        case (.custom(let from), .builtin):
            // Dragged before the custom tabs: put it first among them.
            var tabs = settings.data.customTabs
            guard let fromIndex = tabs.firstIndex(where: { $0.id == from }) else { return }
            let moving = tabs.remove(at: fromIndex)
            tabs.insert(moving, at: 0)
            withAnimation(Motion.tabSwitch) { settings.data.customTabs = tabs }
        }
    }

    private struct DockDropDelegate: DropDelegate {
        let target: ActiveTab
        @Binding var dragging: ActiveTab?
        @Binding var dropTarget: ActiveTab?
        let move: (ActiveTab, ActiveTab) -> Void

        func dropEntered(info: DropInfo) {
            guard dragging != nil, dragging != target else { return }
            dropTarget = target
        }
        func dropExited(info: DropInfo) {
            if dropTarget == target { dropTarget = nil }
        }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
        func performDrop(info: DropInfo) -> Bool {
            defer { dragging = nil; dropTarget = nil }
            guard let source = dragging else { return false }
            move(source, target)
            return true
        }
    }

    // MARK: - Description

    private func describe(_ item: ActiveTab) -> (symbol: String, title: String, tint: Color) {
        switch item {
        case .builtin(let id):
            return (id.symbol, id.title, themes.theme.tint(id.tint))
        case .custom(let uuid):
            guard let config = settings.data.customTabs.first(where: { $0.id == uuid }) else {
                return ("questionmark.square.dashed", "Missing", themes.theme.secondaryText)
            }
            return (config.symbol.isEmpty ? config.kind.symbol : config.symbol,
                    config.title,
                    themes.theme.tint(.custom))
        }
    }

    private func identifier(_ item: ActiveTab) -> String {
        switch item {
        case .builtin(let id):  return "builtin:" + id.rawValue
        case .custom(let uuid): return "custom:" + uuid.uuidString
        }
    }
}

/// The "+" popover: hidden built-ins on one side, a new custom tab on the other.
///
/// Both live here because to the user they are one question -- "what else can I
/// put in this bar" -- even though internally one is unhiding an enum case and
/// the other is appending a config record.
struct AddTabPopover: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var controller: NotchPanelController
    @Binding var isPresented: Bool

    @State private var kind: CustomTabKind = .webView
    @State private var title = ""
    @State private var url = ""
    @State private var jsonPath = ""
    @State private var tag = ""

    var body: some View {
        let theme = themes.theme
        VStack(alignment: .leading, spacing: 9) {
            let hidden = TabID.allCases.filter { !settings.data.enabledTabs.contains($0.rawValue) }
            if !hidden.isEmpty {
                NBSectionHeader(title: "Hidden tabs")
                FlowRow(spacing: 5) {
                    ForEach(hidden) { id in
                        Button {
                            settings.data.enabledTabs.append(id.rawValue)
                            controller.openTab(.builtin(id))
                            isPresented = false
                        } label: {
                            Label(id.title, systemImage: id.symbol).font(.system(size: 10))
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(id.tint), compact: true))
                    }
                }
                Divider().overlay(theme.panelStroke)
            }

            NBSectionHeader(title: "New tab")
            Text("A custom tab is configuration, never code. There is no plugin runtime, so adding one cannot introduce a security surface or a per-plugin memory cost.")
                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $kind) {
                ForEach(CustomTabKind.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()

            NBTextField(placeholder: "Tab name", text: $title)

            switch kind {
            case .webView:
                NBTextField(placeholder: "https://…", text: $url, monospaced: true)
            case .metric:
                NBTextField(placeholder: "https://api.example.com/stats", text: $url, monospaced: true)
                NBTextField(placeholder: "JSON path, e.g. data.today.total", text: $jsonPath, monospaced: true)
            case .snippetList:
                NBTextField(placeholder: "Tag to show", text: $tag)
            case .launcher:
                Text("Add apps from the tab itself once it exists.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                Button("Add tab") { add() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.custom), filled: true, compact: true))
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func add() {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var config = CustomTabConfig(kind: kind, title: name, symbol: kind.symbol)
        config.url = url
        config.jsonPath = jsonPath
        config.snippetTagFilter = tag
        settings.data.customTabs.append(config)
        controller.openTab(.custom(config.id))
        isPresented = false
        title = ""; url = ""; jsonPath = ""; tag = ""
    }
}
