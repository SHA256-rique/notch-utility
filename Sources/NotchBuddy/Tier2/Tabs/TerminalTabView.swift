import SwiftUI
import AppKit

/// Terminal: a real pty-backed shell, and the place the owned-pty approval path
/// becomes available.
struct TerminalTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var session = TerminalSession.shared
    @ObservedObject private var center = ApprovalCenter.shared
    @State private var showSetup = false

    /// A fixed monospaced metric. Measuring the advance once and laying out on a
    /// strict grid is what lets the renderer be a single Canvas pass -- a
    /// proportional or dynamically-measured font would force per-glyph layout.
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private var cellSize: CGSize {
        let advance = font.maximumAdvancement.width
        return CGSize(width: advance, height: ceil(font.ascender - font.descender + font.leading) + 1)
    }

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
                let columns = max(20, Int(geo.size.width / cellSize.width))
                let rows = max(4, Int(geo.size.height / cellSize.height))

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.55)
                    TerminalGridView(session: session, font: font, cellSize: cellSize)
                        .padding(.leading, 6).padding(.top, 4)
                    TerminalKeyCatcher(session: session)
                        .frame(width: 0, height: 0)

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
                .onAppear {
                    session.start(columns: columns, rows: rows)
                    // Attaching the detector here -- not in the session -- keeps
                    // the approval feature opt-in-by-presence: no Terminal tab
                    // open means no pattern matching running.
                    OwnedPTYDetector.shared.attach(to: session)
                }
                .onChange(of: geo.size) {
                    session.resize(columns: columns, rows: rows)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.top, center.current != nil ? 8 : 8)

            HStack(spacing: 6) {
                Circle().fill(session.isRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(session.isRunning ? "Shell running" : "No session")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                Text("· approvals from agents run here are intercepted at the pty")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.75))
                Spacer()
                Button(showSetup ? "Hide setup" : "Approval setup") {
                    withAnimation(Motion.sheet) { showSetup.toggle() }
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.approval), compact: true))
                Button("Restart") {
                    session.forceStop()
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            if showSetup {
                ScrollView {
                    ApprovalStatusView().padding(.horizontal, 12).padding(.bottom, 12)
                }
                .frame(maxHeight: 200)
            }
        }
        .onDisappear {
            OwnedPTYDetector.shared.detach()
            // Honours the "keep alive in background" setting internally; by
            // default this kills the process group and frees the buffers.
            session.stop()
        }
    }
}
