import SwiftUI
import AppKit

/// Terminal: a real pty-backed shell, and the place the owned-pty approval path
/// becomes available.
///
/// ## The chrome
/// The grid alone reads as a text dump pasted into a panel. What makes a
/// terminal feel like a terminal is the frame around it: a title strip that says
/// what shell you are in and how big it is, a cursor that blinks while focused
/// and goes hollow when it is not, selectable text, and scrollback you can
/// actually reach. Those are all here, and each is small -- but their absence is
/// what "it doesn't feel like a terminal" actually means.
///
/// The one thing deliberately not copied from a real terminal emulator is tabs
/// and splits. This is a 680pt panel hanging off a notch; a second pane would
/// leave each one too narrow to run anything.
struct TerminalTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var session = TerminalSession.shared
    @ObservedObject private var center = ApprovalCenter.shared
    @State private var showSetup = false
    @State private var selection: TerminalSelection?
    @State private var isFocused = false
    @State private var cursorOn = true
    @State private var blinkToken: UUID?
    @AppStorage("terminal.fontSize") private var fontSize: Double = 11

    /// A fixed monospaced metric. Measuring the advance once and laying out on a
    /// strict grid is what lets the renderer be a single Canvas pass -- a
    /// proportional or dynamically-measured font would force per-glyph layout.
    private var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }
    private var cellSize: CGSize {
        let font = self.font
        return CGSize(width: font.maximumAdvancement.width,
                      height: ceil(font.ascender - font.descender + font.leading) + 1)
    }

    private let gutter = CGSize(width: 8, height: 5)

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
                let columns = max(20, Int((geo.size.width - gutter.width * 2) / cellSize.width))
                let rows = max(4, Int((geo.size.height - titleBarHeight - gutter.height * 2) / cellSize.height))

                VStack(spacing: 0) {
                    titleBar(columns: columns, rows: rows, theme: theme)

                    ZStack(alignment: .topLeading) {
                        // A very slight vertical gradient rather than flat
                        // black: it separates the terminal from the panel's own
                        // dark background, which flat black does not.
                        LinearGradient(colors: [Color.black.opacity(0.72), Color.black.opacity(0.58)],
                                       startPoint: .top, endPoint: .bottom)

                        TerminalGridView(session: session, font: font, cellSize: cellSize,
                                         selection: $selection,
                                         cursorOn: cursorOn, isFocused: isFocused)
                            .padding(.leading, gutter.width)
                            .padding(.top, gutter.height)
                            .contentShape(Rectangle())
                            .gesture(selectionGesture)

                        TerminalKeyCatcher(
                            session: session,
                            selectedText: { selectedText() },
                            onScroll: { session.emulator.scroll(by: $0); session.bumpGeneration() },
                            onFocusChange: { isFocused = $0 },
                            onFontStep: { step in
                                fontSize = min(20, max(9, fontSize + Double(step)))
                            })
                            .frame(width: 0, height: 0)

                        if session.emulator.isScrolledBack {
                            jumpToBottom(theme)
                        }

                        if !session.isRunning {
                            VStack(spacing: 8) {
                                Text(session.exitMessage ?? "Starting shell…")
                                    .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                                if session.exitMessage != nil {
                                    Button("Start a new session") {
                                        session.start(columns: columns, rows: rows)
                                        OwnedPTYDetector.shared.attach(to: session)
                                    }
                                    .buttonStyle(NBButtonStyle(tint: theme.tint(.terminal), filled: true))
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.6))
                        }
                    }
                }
                .onAppear {
                    session.start(columns: columns, rows: rows)
                    // Attaching the detector here -- not in the session -- keeps
                    // the approval feature opt-in-by-presence: no Terminal tab
                    // open means no pattern matching running.
                    OwnedPTYDetector.shared.attach(to: session)
                    startBlink()
                }
                .onChange(of: geo.size) {
                    session.resize(columns: columns, rows: rows)
                }
                .onChange(of: fontSize) {
                    session.resize(columns: columns, rows: rows)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isFocused ? theme.tint(.terminal).opacity(0.45) : theme.panelStroke,
                            lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .animation(Motion.tabSwitch, value: isFocused)

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
            // Honours the "keep alive in background" setting internally; by
            // default this kills the process group and frees the buffers.
            session.stop()
        }
    }

    // MARK: - Chrome

    private let titleBarHeight: CGFloat = 22

    private func titleBar(columns: Int, rows: Int, theme: Theme) -> some View {
        HStack(spacing: 6) {
            Circle().fill(session.isRunning ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
                .themeGlow(session.isRunning ? .green : .clear, radius: theme.glowRadius(4))
            Text(shellName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.primaryText.opacity(0.85))
            Text("\(columns)×\(rows)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
            Spacer()

            if selection != nil {
                Button("Copy") { copySelection() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.terminal), compact: true))
            }

            Button {
                fontSize = max(9, fontSize - 1)
            } label: { Image(systemName: "textformat.size.smaller").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                .help("Smaller text (⌘−)")
            Button {
                fontSize = min(20, fontSize + 1)
            } label: { Image(systemName: "textformat.size.larger").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                .help("Larger text (⌘+)")
        }
        .padding(.horizontal, 9)
        .frame(height: titleBarHeight)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.panelStroke).frame(height: 0.5)
        }
    }

    private func jumpToBottom(_ theme: Theme) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    session.emulator.scrollToBottom()
                    session.bumpGeneration()
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

    private func statusBar(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            Text(session.emulator.isScrolledBack
                 ? "Scrolled back — new output is still arriving below"
                 : "Approvals from agents run here are intercepted at the pty")
                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            Spacer()
            Button(showSetup ? "Hide setup" : "Approval setup") {
                withAnimation(Motion.sheet) { showSetup.toggle() }
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.approval), compact: true))
            Button("Restart") { session.forceStop() }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var shellName: String {
        let configured = Settings.shared.data.terminalShell
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : configured
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Selection

    /// Drag to select. `minimumDistance: 2` so a plain click -- which is how you
    /// focus the terminal -- clears the selection instead of creating a
    /// zero-width one that then blocks ctrl-C.
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let anchor = position(at: value.startLocation)
                let head = position(at: value.location)
                selection = TerminalSelection(anchor: anchor, head: head)
            }
            .simultaneously(with: TapGesture().onEnded { selection = nil })
    }

    private func position(at point: CGPoint) -> TerminalEmulator.Position {
        let emulator = session.emulator
        let row = Int((point.y - gutter.height) / cellSize.height)
        let column = Int((point.x - gutter.width) / cellSize.width)
        return TerminalEmulator.Position(
            line: max(0, emulator.firstVisibleLineIndex + max(0, min(emulator.rows - 1, row))),
            column: max(0, min(emulator.columns - 1, column)))
    }

    private func selectedText() -> String? {
        guard let selection, !selection.isEmpty else { return nil }
        let text = session.emulator.text(from: selection.start, to: selection.end)
        return text.isEmpty ? nil : text
    }

    private func copySelection() {
        guard let text = selectedText() else { return }
        ClipboardWatcher.shared.suppressNextChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NotchArbiter.shared.flash("Copied", symbol: "doc.on.doc.fill",
                                  module: .terminal, detail: "\(text.count) chars")
    }

    // MARK: - Cursor blink

    /// The blink is a hub registration like everything else, so it is torn down
    /// with the tab and cannot become a timer that outlives the view. 0.53s is
    /// the rate VT100 hardware used and every terminal since has copied; it is
    /// slow enough not to read as a flicker.
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
