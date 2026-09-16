import SwiftUI
import UniformTypeIdentifiers

/// The dock of tab icons, along the **bottom** of the expanded panel.
///
/// ## Why the bottom
/// It used to run along the top, which put it directly under the camera
/// housing. macOS reserves that rectangle -- no application can draw into it,
/// which is why every notch app works *around* the cutout rather than under it
/// -- so the middle three or four icons were permanently invisible on a notched
/// MacBook. A row of controls you cannot see is not a row of controls.
///
/// The bottom edge of a 470pt panel is nowhere near the notch, and it leaves the
/// top edge free for the only two things that genuinely belong beside the
/// cutout: pin and close, out on the right shoulder.
///
/// ## Magnification
/// Centred, and magnified on hover like the system Dock. That is not
/// decoration: the icons are small and monochrome, and at that size the
/// difference between "terminal" and "API" is a few pixels of glyph.
/// Magnification is what makes a dense monochrome strip legible without making
/// every icon permanently large.
struct TabDockView: View {
    @EnvironmentObject private var controller: NotchPanelController
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings

    @State private var dragging: ActiveTab?
    @State private var dropTarget: ActiveTab?
    @State private var showAdd = false
    @State private var hoveringClose: DetailTab?
    /// Cursor position in the dock's own coordinate space, or nil when the
    /// pointer is elsewhere. Drives the magnification falloff.
    @State private var hoverX: CGFloat?
    /// Each item's centre, reported up from the items themselves so the falloff
    /// works for variable-width detail tabs as well as fixed-width icons.
    @State private var centres: [ActiveTab: CGFloat] = [:]

    /// How much the item directly under the cursor grows.
    private let peakScale: CGFloat = 1.45
    /// How far the magnification reaches either side, in points -- about two
    /// icons' worth. Far enough to read as a smooth wave, near enough that the
    /// whole dock does not heave every time the cursor passes.
    private let falloff: CGFloat = 58

    static let dockSpace = "notchbuddy.dock"

    var body: some View {
        let theme = themes.theme
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(items, id: \.self) { item in
                        button(for: item, theme: theme)
                    }

                    // Detail tabs sit after a divider, carry a label and a close
                    // button, and are not draggable. All three differences say
                    // the same thing: these are temporary and the permanent ones
                    // are over there.
                    if !controller.openDetails.isEmpty {
                        Rectangle()
                            .fill(theme.panelStroke)
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 3)
                        ForEach(controller.openDetails) { detail in
                            detailButton(detail, theme: theme)
                        }
                    }

                    addButton(theme)
                }
                .padding(.horizontal, 8)
                // Room for the magnified icons to grow into. Without it the
                // scaled icon is clipped at the moment it becomes largest,
                // which reads as a glitch rather than as a zoom.
                .padding(.top, 10)
                .padding(.bottom, 4)
                .animation(Motion.tabSwitch, value: controller.openDetails)
                .coordinateSpace(name: Self.dockSpace)
                .onPreferenceChange(DockCentrePreference.self) { centres = $0 }
            }
            // `fixedSize` lets the strip be its natural width so the spacers can
            // centre it; the scroll view only engages once it outgrows the panel.
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .onContinuousHover(coordinateSpace: .named(Self.dockSpace)) { phase in
            switch phase {
            case .active(let point): hoverX = point.x
            case .ended:             hoverX = nil
            }
        }
        .animation(Motion.dockMagnify, value: hoverX)
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.035))
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.panelStroke).frame(height: 0.5)
                }
        )
    }

    /// Dock-style falloff: 1.0 far away, `peakScale` directly underneath, with a
    /// cosine ramp between so neighbours rise smoothly instead of snapping.
    private func scale(for item: ActiveTab) -> CGFloat {
        guard let hoverX, let centre = centres[item] else { return 1 }
        let distance = abs(hoverX - centre)
        guard distance < falloff else { return 1 }
        let t = distance / falloff
        return 1 + (peakScale - 1) * (cos(t * .pi) + 1) / 2
    }

    // MARK: - Built-in and custom tabs

    @ViewBuilder
    private func button(for item: ActiveTab, theme: Theme) -> some View {
        let info = describe(item)
        let isActive = controller.activeTab == item
        let magnification = scale(for: item)

        Button {
            controller.openTab(item)
        } label: {
            Image(systemName: info.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(isActive ? info.tint : theme.secondaryText)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? info.tint.opacity(0.18) : .clear)
                )
                .themeGlow(info.tint, radius: isActive ? theme.glowRadius(5) : 0)
                .overlay(alignment: .bottom) {
                    // A custom tab is otherwise pixel-identical to a built-in,
                    // which makes "where did my tab go" a fair question. A dot
                    // answers it without adding a row of labels.
                    if info.isCustom {
                        Circle()
                            .fill(theme.tint(.custom))
                            .frame(width: 3, height: 3)
                            .offset(y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(info.title)
        // Scale from the bottom so magnified icons grow upward out of the row
        // rather than pushing through the panel's bottom edge.
        .scaleEffect(magnification, anchor: .bottom)
        .zIndex(magnification > 1.01 ? 1 : 0)
        .opacity(dragging == item ? 0.3 : 1)
        .overlay(alignment: .leading) {
            if dropTarget == item, dragging != item {
                Capsule().fill(info.tint).frame(width: 2)
                    .offset(x: -2)
                    .transition(.opacity)
            }
        }
        .reportDockCentre(for: item)
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

    // MARK: - Detail tabs

    private func detailButton(_ detail: DetailTab, theme: Theme) -> some View {
        let item = ActiveTab.detail(detail)
        let isActive = controller.activeTab == item
        let tint = theme.tint(detail.tint)
        let magnification = scale(for: item)
        return HStack(spacing: 4) {
            Image(systemName: detail.symbol)
                .font(.system(size: 11, weight: .medium))
            Text(detail.shortTitle)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)

            Button {
                controller.closeDetail(detail)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 12, height: 12)
                    .background(Circle().fill(Color.white.opacity(hoveringClose == detail ? 0.18 : 0)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hoveringClose = $0 ? detail : (hoveringClose == detail ? nil : hoveringClose) }
            .help("Close \(detail.title)")
        }
        .foregroundStyle(isActive ? tint : theme.secondaryText)
        .padding(.leading, 8).padding(.trailing, 5)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? tint.opacity(0.18) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(isActive ? tint.opacity(0.4) : theme.panelStroke.opacity(0.7))
                )
        )
        .contentShape(Rectangle())
        .pointerCursor()
        .scaleEffect(magnification, anchor: .bottom)
        .zIndex(magnification > 1.01 ? 1 : 0)
        .reportDockCentre(for: item)
        .onTapGesture { controller.openTab(item) }
        .contextMenu {
            Button("Close") { controller.closeDetail(detail) }
            Button("Close all details") { controller.closeAllDetails() }
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: - Add

    private func addButton(_ theme: Theme) -> some View {
        Button {
            showAdd.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 24)
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
        .padding(.leading, 3)
        // The popover hangs upward now that the dock is at the bottom.
        .popover(isPresented: $showAdd, arrowEdge: .top) {
            AddTabPopover(isPresented: $showAdd)
                .environmentObject(themes)
                .environmentObject(settings)
                .environmentObject(controller)
        }
    }

    /// Built-ins in the user's order, then custom tabs. One flat list so the
    /// drop delegate does not need to know which kind it is moving.
    private var items: [ActiveTab] {
        settings.data.enabledTabs.compactMap(TabID.init(rawValue:)).map(ActiveTab.builtin)
            + settings.data.customTabs.map { ActiveTab.custom($0.id) }
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

        case (.detail, _), (_, .detail):
            // Details are ephemeral and ordered by when they were opened.
            // Dragging one would imply an arrangement worth keeping, and there
            // is nothing to keep it in.
            break
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

    private func describe(_ item: ActiveTab) -> (symbol: String, title: String, tint: Color, isCustom: Bool) {
        switch item {
        case .builtin(let id):
            return (id.symbol, id.title, themes.theme.tint(id.tint), false)
        case .custom(let uuid):
            guard let config = settings.data.customTabs.first(where: { $0.id == uuid }) else {
                return ("questionmark.square.dashed", "Missing", themes.theme.secondaryText, true)
            }
            return (config.symbol.isEmpty ? config.kind.symbol : config.symbol,
                    config.title,
                    themes.theme.tint(.custom),
                    true)
        case .detail(let detail):
            return (detail.symbol, detail.title, themes.theme.tint(detail.tint), false)
        }
    }

    private func identifier(_ item: ActiveTab) -> String {
        switch item {
        case .builtin(let id):    return "builtin:" + id.rawValue
        case .custom(let uuid):   return "custom:" + uuid.uuidString
        case .detail(let detail): return "detail:" + detail.rawValue
        }
    }
}

// MARK: - Centre reporting

/// Collects each dock item's horizontal centre so magnification can fall off by
/// distance. A preference key rather than arithmetic over an index, because
/// detail tabs are text-width and the arithmetic would be wrong the moment one
/// opened.
private struct DockCentrePreference: PreferenceKey {
    static var defaultValue: [ActiveTab: CGFloat] { [:] }
    static func reduce(value: inout [ActiveTab: CGFloat], nextValue: () -> [ActiveTab: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func reportDockCentre(for item: ActiveTab) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: DockCentrePreference.self,
                    value: [item: geo.frame(in: .named(TabDockView.dockSpace)).midX])
            }
        )
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
                NBTextField(placeholder: "google.com", text: $url, monospaced: true)
                Text("A bare domain is fine — https:// is added for you.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
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
        config.url = CustomTabConfig.normalisedURL(url)
        config.jsonPath = jsonPath
        config.snippetTagFilter = tag
        settings.data.customTabs.append(config)
        controller.openTab(.custom(config.id))
        isPresented = false
        title = ""; url = ""; jsonPath = ""; tag = ""
    }
}
