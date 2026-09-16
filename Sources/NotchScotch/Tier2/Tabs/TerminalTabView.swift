import SwiftUI
import AppKit

/// Terminal: up to four real pty-backed shells, and the place the owned-pty
/// approval path becomes available.
///
/// ## The chrome
/// The grid alone reads as a text dump pasted into a panel. What makes a
/// terminal feel like a terminal is the frame around it: a title strip saying
/// what shell you are in and where, a cursor that blinks while focused and goes
/// hollow when it is not, selectable text, and scrollback you can reach.
///
/// ## Panes
/// Splits are tmux-shaped but fixed: five presets covering everything worth
/// arranging at this size, rather than an arbitrary pane tree that would need a
/// splitter widget, drag-to-resize and a persistence format. See
/// `TerminalWorkspace` for why four is the cap.
///
/// The approval detector attaches to the **focused** pane only. Watching all
/// four would mean four pattern matchers against four byte streams, producing a
/// badge that could not say which pane was blocked.
struct TerminalTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var workspace = TerminalWorkspace.shared
    @ObservedObject private var center = ApprovalCenter.shared
    @ObservedObject private var settings = Settings.shared
    @State private var showSetup = false
    @State private var cursorOn = true
    @State private var blinkToken: UUID?
    @AppStorage("terminal.fontSize") private var fontSize: Double = 11

    /// A fixed monospaced metric. Measuring the advance once and laying out on a
    /// strict grid is what lets each pane render in a single Canvas pass.
    private var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }
    private var cellSize: CGSize {
        let font = self.font
        return CGSize(width: font.maximumAdvancement.width,
                      height: ceil(font.ascender - font.descender + font.leading) + 1)
    }

    private let gutter = CGSize(width: 8, height: 5)
    private let titleBarHeight: CGFloat = 22
    private let paneGap: CGFloat = 6

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 0) {
            // A pending approval floats above the terminal rather than replacing
            // it, so the user can read the surrounding output while deciding.
            if center.current != nil {
                ApprovalView()
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    paneLayout(in: geo.size, theme: theme)

                    // ONE key catcher for the tab, pointed at whichever pane has
                    // focus -- not one per pane.
                    //
                    // The per-pane version is why typing did not work in a
                    // split. Changing focus destroyed one catcher and created
                    // another, and SwiftUI gives no ordering guarantee between
                    // the two: the outgoing view frequently resigned first
                    // responder *after* the incoming one claimed it, leaving the
                    // window with no responder at all. The single catcher never
                    // moves, so there is no handover to lose.
                    TerminalKeyCatcher(
                        session: workspace.focusedPane,
                        selectedText: { workspace.focusedSelectionText() },
                        onScroll: {
                            workspace.focusedPane.emulator.scroll(by: $0)
                            workspace.focusedPane.bumpGeneration()
                        },
                        onFocusChange: { _ in },
                        onFontStep: { fontSize = min(20, max(9, fontSize + Double($0))) })
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                    .onAppear {
                        workspace.startAll { paneMetrics(index: $0, in: geo.size).grid }
                        OwnedPTYDetector.shared.attach(to: workspace.focusedPane)
                        startBlink()
                    }
                    .onChange(of: geo.size) {
                        workspace.resizeAll { paneMetrics(index: $0, in: geo.size).grid }
                    }
                    .onChange(of: fontSize) {
                        workspace.resizeAll { paneMetrics(index: $0, in: geo.size).grid }
                    }
                    .onChange(of: workspace.layout) {
                        // A new pane has to be started and every existing one
                        // re-sized: splitting changes how many columns each has,
                        // and a pty told the wrong width wraps in the wrong place.
                        workspace.startAll { paneMetrics(index: $0, in: geo.size).grid }
                        workspace.resizeAll { paneMetrics(index: $0, in: geo.size).grid }
                    }
                    .onChange(of: workspace.focused) {
                        OwnedPTYDetector.shared.detach()
                        OwnedPTYDetector.shared.attach(to: workspace.focusedPane)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            statusBar(theme)

            if showSetup {
                ScrollView {
                    ApprovalStatusView().padding(.horizontal, 12).padding(.bottom, 12)
                }
                .frame(maxHeight: 200)
            }
        }
        .onDisappear {
            stopBlink()
            OwnedPTYDetector.shared.detach()
            // Honours "keep alive in background" for the first pane only.
            workspace.stopAll()
        }
    }

    // MARK: - Layout

    /// Frames for each pane, in the terminal area's own coordinates.
    ///
    /// Computed rather than expressed as nested stacks because each pane needs
    /// its own pixel size to work out its column and row count, and SwiftUI
    /// will not tell a child what it was given until after layout.
    private func paneFrames(in size: CGSize) -> [CGRect] {
        let w = size.width, h = size.height

        switch workspace.layout {
        case .single:
            return [CGRect(x: 0, y: 0, width: w, height: h)]

        case .columns:
            let paneWidth = (w - paneGap) / 2
            return [CGRect(x: 0, y: 0, width: paneWidth, height: h),
                    CGRect(x: paneWidth + paneGap, y: 0, width: paneWidth, height: h)]

        case .rows:
            let paneHeight = (h - paneGap) / 2
            return [CGRect(x: 0, y: 0, width: w, height: paneHeight),
                    CGRect(x: 0, y: paneHeight + paneGap, width: w, height: paneHeight)]

        case .mainLeft:
            // 56/44 rather than half and half: the main pane is the one you are
            // working in and the other two are things you are watching.
            let mainWidth = (w - paneGap) * 0.56
            let sideWidth = w - mainWidth - paneGap
            let sideHeight = (h - paneGap) / 2
            return [CGRect(x: 0, y: 0, width: mainWidth, height: h),
                    CGRect(x: mainWidth + paneGap, y: 0, width: sideWidth, height: sideHeight),
                    CGRect(x: mainWidth + paneGap, y: sideHeight + paneGap,
                           width: sideWidth, height: sideHeight)]

        case .grid:
            let paneWidth = (w - paneGap) / 2
            let paneHeight = (h - paneGap) / 2
            return (0..<4).map { index in
                CGRect(x: index % 2 == 0 ? 0 : paneWidth + paneGap,
                       y: index < 2 ? 0 : paneHeight + paneGap,
                       width: paneWidth, height: paneHeight)
            }
        }
    }

    private func paneMetrics(index: Int, in size: CGSize) -> (frame: CGRect, grid: (columns: Int, rows: Int)) {
        let frames = paneFrames(in: size)
        let frame = frames.indices.contains(index) ? frames[index] : CGRect(origin: .zero, size: size)
        let columns = max(20, Int((frame.width - gutter.width * 2) / cellSize.width))
        let rows = max(4, Int((frame.height - titleBarHeight - gutter.height * 2) / cellSize.height))
        return (frame, (columns, rows))
    }

    private func paneLayout(in size: CGSize, theme: Theme) -> some View {
        let frames = paneFrames(in: size)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(workspace.panes.enumerated()), id: \.element.id) { index, pane in
                let frame = frames.indices.contains(index) ? frames[index] : .zero
                paneView(pane, index: index, theme: theme)
                    .frame(width: max(1, frame.width), height: max(1, frame.height))
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(Motion.sheet, value: workspace.layout)
    }

    // MARK: - One pane

    private func paneView(_ pane: TerminalSession, index: Int, theme: Theme) -> some View {
        let isFocused = workspace.focused == index
        let split = workspace.panes.count > 1
        return VStack(spacing: 0) {
            paneTitleBar(pane, index: index, isFocused: isFocused, theme: theme)
            TerminalPaneBody(workspace: workspace, pane: pane, font: font, cellSize: cellSize,
                             gutter: gutter, isFocused: isFocused, cursorOn: cursorOn,
                             onFocus: { workspace.focused = index })
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isFocused ? theme.tint(.terminal).opacity(split ? 0.7 : 0.45) : theme.panelStroke,
                        lineWidth: isFocused && split ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { workspace.focused = index }
        .animation(Motion.tabSwitch, value: isFocused)
    }

    private func paneTitleBar(_ pane: TerminalSession, index: Int,
                              isFocused: Bool, theme: Theme) -> some View {
        HStack(spacing: 6) {
            Circle().fill(pane.isRunning ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
                .themeGlow(pane.isRunning ? .green : .clear, radius: theme.glowRadius(4))
            Text(shellName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.primaryText.opacity(isFocused ? 0.9 : 0.55))
            if let directory = pane.workingDirectory {
                Text(Self.abbreviate(directory))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 2)

            if workspace.panes.count > 1 {
                Button {
                    workspace.closePane(at: index)
                } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).pointerCursor()
                    .foregroundStyle(theme.secondaryText)
                    .help("Close this pane")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: titleBarHeight)
        .background(Color.white.opacity(isFocused ? 0.07 : 0.03))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.panelStroke).frame(height: 0.5)
        }
    }

    // MARK: - Status bar

    private func statusBar(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { workspace.layout },
                set: { workspace.setLayout($0) })) {
                ForEach(TerminalWorkspace.Layout.allCases) { layout in
                    Image(systemName: layout.symbol).tag(layout)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            .help("Pane layout")

            Button {
                workspace.split()
            } label: {
                Image(systemName: "plus.rectangle").font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.terminal), compact: true))
            .disabled(!workspace.canSplit)
            .help(workspace.canSplit
                  ? "Add a pane"
                  : "Four is the limit — below that each pane is too narrow to read a stack trace")

            Divider().frame(height: 14).overlay(theme.panelStroke)

            Button {
                workspace.handOffToExternalTerminal()
            } label: {
                Label("Open in \(externalTerminalName)", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.terminal), compact: true))
            .help("Opens the focused pane's directory there, and copies its scrollback to the clipboard")

            Picker("", selection: $settings.data.externalTerminalBundleID) {
                ForEach(TerminalWorkspace.installedTerminals()) { terminal in
                    Text(terminal.name).tag(terminal.bundleID)
                }
            }
            .labelsHidden().frame(width: 92)

            Spacer(minLength: 4)

            Button(showSetup ? "Hide setup" : "Approvals") {
                withAnimation(Motion.sheet) { showSetup.toggle() }
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.approval), compact: true))
            Button("Restart") { workspace.focusedPane.forceStop() }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var externalTerminalName: String {
        TerminalWorkspace.knownTerminals
            .first { $0.bundleID == settings.data.externalTerminalBundleID }?.name ?? "Terminal"
    }

    private var shellName: String {
        let configured = settings.data.terminalShell
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : configured
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// `~/Documents/notch-utility`, and only the tail when even that is long.
    /// A pane title bar can be 200pt wide in a four-way split.
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortened = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = shortened.split(separator: "/")
        guard parts.count > 3 else { return shortened }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    // MARK: - Cursor blink

    /// One registration for every pane, not one each: they should blink in
    /// phase, and four registrations at 0.53s is four times the wakeups for an
    /// effect that is visually identical.
    private func startBlink() {
        guard blinkToken == nil else { return }
        blinkToken = WidgetPollingHub.shared.register(label: "terminal-cursor", interval: 0.53) {
            Task { @MainActor in cursorOn.toggle() }
        }
    }

    private func stopBlink() {
        WidgetPollingHub.shared.unregister(blinkToken)
        blinkToken = nil
        cursorOn = true
    }
}

/// One pane's terminal surface: background, grid, key catcher, scroll affordance.
///
/// Split out of `TerminalTabView` because each pane owns its own selection.
/// `@State` in the parent would have made that shared, so dragging in one pane
/// would have highlighted the same cells in all four.
struct TerminalPaneBody: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var pane: TerminalSession
    let font: NSFont
    let cellSize: CGSize
    let gutter: CGSize
    let isFocused: Bool
    let cursorOn: Bool
    let onFocus: () -> Void

    /// Selection lives in the workspace, not here.
    ///
    /// The tab mounts one key catcher for all panes (see `TerminalTabView`), and
    /// cmd-C in that catcher has to read the *focused* pane's selection. Per-pane
    /// `@State` was invisible to it.
    private var selection: TerminalSelection? { workspace.selection(for: pane) }

    var body: some View {
        let theme = themes.theme
        ZStack(alignment: .topLeading) {
            // A very slight vertical gradient rather than flat black: it
            // separates the terminal from the panel's own dark background,
            // which flat black does not.
            LinearGradient(colors: [Color.black.opacity(0.72), Color.black.opacity(0.58)],
                           startPoint: .top, endPoint: .bottom)

            TerminalGridView(session: pane, font: font, cellSize: cellSize,
                             selection: Binding(
                                get: { workspace.selection(for: pane) },
                                set: { workspace.setSelection($0, for: pane) }),
                             cursorOn: cursorOn, isFocused: isFocused)
                .padding(.leading, gutter.width)
                .padding(.top, gutter.height)
                .contentShape(Rectangle())
                .gesture(selectionGesture)

            if pane.emulator.isScrolledBack {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            pane.emulator.scrollToBottom()
                            pane.bumpGeneration()
                        } label: {
                            Label("Jump to bottom", systemImage: "arrow.down.to.line")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.terminal), filled: true, compact: true))
                        .padding(8)
                    }
                }
                .transition(.opacity)
            }

            if !pane.isRunning {
                Text(pane.exitMessage ?? "Starting shell…")
                    .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
            }
        }
    }

    /// Drag to select. `minimumDistance: 2` so a plain click -- which is how you
    /// focus a pane -- clears the selection instead of creating a zero-width one
    /// that then swallows ctrl-C.
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                onFocus()
                workspace.setSelection(
                    TerminalSelection(anchor: position(at: value.startLocation),
                                      head: position(at: value.location)),
                    for: pane)
            }
            .simultaneously(with: TapGesture().onEnded {
                workspace.setSelection(nil, for: pane)
                onFocus()
            })
    }

    private func position(at point: CGPoint) -> TerminalEmulator.Position {
        let emulator = pane.emulator
        let row = Int((point.y - gutter.height) / cellSize.height)
        let column = Int((point.x - gutter.width) / cellSize.width)
        return TerminalEmulator.Position(
            line: max(0, emulator.firstVisibleLineIndex + max(0, min(emulator.rows - 1, row))),
            column: max(0, min(emulator.columns - 1, column)))
    }
}
