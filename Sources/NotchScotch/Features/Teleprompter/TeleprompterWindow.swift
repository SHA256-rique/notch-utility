import AppKit
import SwiftUI
import Combine

/// Teleprompter: a separate always-on-top window, launched from the notch but
/// completely independent of it.
///
/// ## Why its own window and not a notch tab
/// The use case is reading a script while on a video call. The call app will be
/// focused and often full-screen; the notch panel collapses when you stop
/// hovering it. A teleprompter that disappears the moment you look away from it
/// is not a teleprompter. So it gets its own window with its own lifetime.
///
/// ## Hidden from screen recording by default
/// `NSWindow.sharingType = .none` makes the window invisible to the window
/// server's capture path -- screen recording, screen sharing, and screenshots.
/// It is the same mechanism password managers use to keep vaults out of
/// screenshots.
///
/// This is the entire point of the feature (your audience must not see your
/// script), so it defaults ON here. The toggle itself is general and lives in
/// Settings, available for the notch panel too.
///
/// One honest caveat worth knowing: `.none` hides the window from *software*
/// capture on the same machine. It is not a defence against a phone pointed at
/// the screen, and it does not survive some virtualisation setups.
@MainActor
final class TeleprompterController: ObservableObject {
    static let shared = TeleprompterController()

    @Published var script: String = ""
    @Published var fontSize: Double = 34
    @Published var speed: Double = 40           // points per second
    @Published var isMirrored = false
    @Published var isRunning = false
    @Published var countdown: Int = 0
    @Published var hideFromCapture = true
    @Published var offset: CGFloat = 0
    @Published private(set) var isOpen = false

    private var window: NSPanel?
    private var scrollSource: DispatchSourceTimer?
    private var countdownSource: DispatchSourceTimer?
    private let store = JSONStore<Saved>(filename: "teleprompter.json", debounce: 1.0)

    private struct Saved: Codable {
        var script = ""
        var fontSize: Double = 34
        var speed: Double = 40
        var isMirrored = false
        var hideFromCapture = true
    }

    private init() {
        let saved = store.load() ?? Saved()
        script = saved.script
        fontSize = saved.fontSize
        speed = saved.speed
        isMirrored = saved.isMirrored
        hideFromCapture = saved.hideFromCapture
    }

    func persist() {
        store.save(Saved(script: script, fontSize: fontSize, speed: speed,
                         isMirrored: isMirrored, hideFromCapture: hideFromCapture))
    }

    // MARK: - Window

    func open() {
        if window == nil {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let size = CGSize(width: min(720, screen.frame.width - 120), height: 320)
            let frame = CGRect(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.maxY - size.height - 120,
                               width: size.width, height: size.height)

            let panel = NSPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Draggable by its background: it has no title bar to grab.
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView:
                TeleprompterView(controller: self)
                    .environmentObject(ThemeManager.shared))
            window = panel
        }
        applyCaptureHiding()
        window?.orderFrontRegardless()
        isOpen = true

        // Get out of the way. The prompter is a performance surface -- you open
        // it because you are about to talk to a camera -- and leaving the notch
        // panel sitting over it means the first thing on screen is a settings
        // panel you now have to dismiss. Everything the prompter needs while
        // running lives in the prompter window itself.
        NotchPanelController.shared.collapse()
    }

    func close() {
        stop()
        window?.orderOut(nil)
        isOpen = false
    }

    func applyCaptureHiding() {
        window?.sharingType = hideFromCapture ? .none : .readOnly
    }

    // MARK: - Scrolling

    func start(countdownSeconds: Int = 3) {
        guard !isRunning else { return }
        guard countdownSeconds > 0 else { beginScroll(); return }
        countdown = countdownSeconds
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.countdown -= 1
            if self.countdown <= 0 {
                self.countdownSource?.cancel()
                self.countdownSource = nil
                self.beginScroll()
            }
        }
        source.resume()
        countdownSource = source
    }

    private func beginScroll() {
        isRunning = true
        // 60Hz scroll while running. This is a genuine animation, so it is one of
        // the very few places in the app that ticks at display rate -- and it
        // only exists while the user has explicitly pressed play in a window
        // they opened on purpose.
        let interval = 1.0 / 60.0
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.offset += CGFloat(self.speed * interval)
        }
        source.resume()
        scrollSource = source
    }

    func stop() {
        isRunning = false
        countdown = 0
        scrollSource?.cancel(); scrollSource = nil
        countdownSource?.cancel(); countdownSource = nil
    }

    func reset() {
        stop()
        offset = 0
    }
}

struct TeleprompterView: View {
    @ObservedObject var controller: TeleprompterController
    @EnvironmentObject private var themes: ThemeManager
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(controller.script.isEmpty
                         ? "Paste your script in the Teleprompter panel, then press play."
                         : controller.script)
                        .font(.system(size: controller.fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(controller.fontSize * 0.35)
                        .multilineTextAlignment(.center)
                        .frame(width: geo.size.width - 48)
                        .padding(.horizontal, 24)
                        // Start below the fold and scroll up past the top, the
                        // way a real teleprompter feeds.
                        .padding(.top, geo.size.height * 0.55)
                        .padding(.bottom, geo.size.height)
                        .offset(y: -controller.offset)
                }
                .scrollDisabled(controller.isRunning)
            }
            // Mirror-flip for a beam-splitter rig, where the text is read off
            // glass and must be reversed.
            .scaleEffect(x: controller.isMirrored ? -1 : 1, y: 1)

            if controller.countdown > 0 {
                Text("\(controller.countdown)")
                    .font(.system(size: 80, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.55))
            }

            if showControls {
                HStack(spacing: 8) {
                    Button {
                        controller.isRunning ? controller.stop() : controller.start()
                    } label: {
                        Image(systemName: controller.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(NBButtonStyle(tint: .white, filled: true, compact: true))

                    Button {
                        controller.reset()
                    } label: { Image(systemName: "backward.end.fill").font(.system(size: 10)) }
                    .buttonStyle(NBButtonStyle(tint: .white, compact: true))

                    Slider(value: $controller.speed, in: 8...160)
                        .controlSize(.mini).frame(width: 90)
                    Text("\(Int(controller.speed))")
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.white.opacity(0.7))

                    Divider().frame(height: 14)

                    Button {
                        controller.fontSize = max(16, controller.fontSize - 3); controller.persist()
                    } label: { Image(systemName: "textformat.size.smaller").font(.system(size: 10)) }
                    .buttonStyle(NBButtonStyle(tint: .white, compact: true))
                    Button {
                        controller.fontSize = min(90, controller.fontSize + 3); controller.persist()
                    } label: { Image(systemName: "textformat.size.larger").font(.system(size: 10)) }
                    .buttonStyle(NBButtonStyle(tint: .white, compact: true))

                    Button {
                        controller.isMirrored.toggle(); controller.persist()
                    } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(NBButtonStyle(tint: .white, filled: controller.isMirrored, compact: true))
                    .help("Mirror for a beam-splitter rig")

                    Button {
                        controller.hideFromCapture.toggle()
                        controller.applyCaptureHiding()
                        controller.persist()
                    } label: {
                        Image(systemName: controller.hideFromCapture ? "eye.slash.fill" : "eye")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(NBButtonStyle(tint: controller.hideFromCapture ? .green : .orange,
                                               filled: controller.hideFromCapture, compact: true))
                    .help(controller.hideFromCapture
                          ? "Hidden from screen recording and sharing"
                          : "VISIBLE to screen recording")

                    Spacer()
                    Button {
                        controller.close()
                    } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(NBButtonStyle(tint: .white, compact: true))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.55))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(controller.hideFromCapture ? Color.green.opacity(0.35) : Color.orange.opacity(0.5),
                            lineWidth: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in withAnimation(Motion.sheet) { showControls = hovering || !controller.isRunning } }
        .animation(Motion.sheet, value: controller.countdown)
    }
}
