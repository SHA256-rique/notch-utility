import AppKit
import SwiftUI
import Combine

enum FlashStyle: String, Codable, CaseIterable, Identifiable {
    case scroll, bounce, wave, sparkle, pulse, rainbow
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .scroll: return "arrow.left.arrow.right"
        case .bounce: return "arrow.up.and.down"
        case .wave: return "waveform"
        case .sparkle: return "sparkles"
        case .pulse: return "circle.circle"
        case .rainbow: return "rainbow"
        }
    }
}

/// Drives the "flash a message across the notch" feature.
///
/// It uses its **own** borderless window rather than the notch panel, for one
/// concrete reason: the message must be able to be much wider than the panel
/// (it scrolls across the top of the display), and it must stay up while the
/// user keeps working -- including while the notch panel itself collapses. Two
/// independent lifetimes means two windows.
@MainActor
final class FlashMessageController: ObservableObject {
    static let shared = FlashMessageController()

    @Published var text: String = ""
    @Published var style: FlashStyle = .scroll
    @Published var speed: Double = 1.0            // multiplier, 0.25...3
    @Published var color: Color = .white
    @Published var useThemeColor: Bool = true
    @Published private(set) var isShowing = false

    private var window: NSWindow?

    private init() {}

    func flash(text: String? = nil) {
        if let text { self.text = text }
        let content = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        show()
        SnippetStore.shared.add(text: content, title: "", tag: "flashed")
    }

    func takeDown() {
        window?.orderOut(nil)
        window = nil
        isShowing = false
    }

    private func show() {
        let layout = ScreenGeometry.current()
        let screen = layout.screen.frame
        // A full-width strip across the top of the display, tall enough to clear
        // the menu bar so the animation has somewhere to go.
        let frame = CGRect(x: screen.minX, y: screen.maxY - 64, width: screen.width, height: 64)

        if window == nil {
            let w = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.ignoresMouseEvents = true   // the message must never eat clicks
            w.isMovable = false
            w.contentView = NSHostingView(rootView:
                FlashMessageView()
                    .environmentObject(self)
                    .environmentObject(ThemeManager.shared))
            window = w
        }
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
        isShowing = true
    }
}

/// The animated banner itself.
///
/// All six styles are expressed as modifiers over one `Text`, driven by a single
/// `TimelineView`. A `TimelineView(.animation)` ties redraws to the display link,
/// so the banner runs at the screen's refresh rate while visible and -- this is
/// the part that matters -- stops entirely the moment the view is removed. No
/// timer to forget to invalidate.
struct FlashMessageView: View {
    @EnvironmentObject private var controller: FlashMessageController
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        let theme = themes.theme
        let tint = controller.useThemeColor ? theme.tint(.message) : controller.color

        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * controller.speed
            GeometryReader { geo in
                content(t: t, width: geo.size.width, tint: tint, theme: theme)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(t: Double, width: CGFloat, tint: Color, theme: Theme) -> some View {
        let label = Text(controller.text)
            .font(.system(size: 26, weight: .bold, design: .rounded))

        switch controller.style {
        case .scroll:
            // Travel one full screen width plus the text's own length, so it
            // enters and exits cleanly.
            let period = 8.0
            let phase = (t.truncatingRemainder(dividingBy: period)) / period
            label.foregroundStyle(tint)
                .themeGlow(tint, radius: theme.glowRadius(8))
                .fixedSize()
                .offset(x: width - CGFloat(phase) * (width * 1.8))
                .frame(maxHeight: .infinity, alignment: .center)

        case .bounce:
            label.foregroundStyle(tint)
                .themeGlow(tint, radius: theme.glowRadius(8))
                .offset(y: CGFloat(sin(t * 3) * 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .wave:
            // Per-character phase offset: the classic wave, and the reason the
            // text is split into characters rather than animated as one block.
            HStack(spacing: 0) {
                ForEach(Array(controller.text.enumerated()), id: \.offset) { index, char in
                    Text(String(char))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .offset(y: CGFloat(sin(t * 4 + Double(index) * 0.35) * 9))
                }
            }
            .themeGlow(tint, radius: theme.glowRadius(6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .sparkle:
            ZStack {
                label.foregroundStyle(tint)
                    .themeGlow(tint, radius: 6 + abs(sin(t * 2)) * 10)
                ForEach(0..<10, id: \.self) { index in
                    let seed = Double(index) * 1.7
                    Image(systemName: "sparkle")
                        .font(.system(size: 9))
                        .foregroundStyle(tint.opacity(0.55 + 0.45 * abs(sin(t * 3 + seed))))
                        .offset(x: CGFloat(sin(t * 0.8 + seed) * 180),
                                y: CGFloat(cos(t * 1.3 + seed) * 18))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .pulse:
            label.foregroundStyle(tint)
                .scaleEffect(1 + 0.08 * sin(t * 4))
                .themeGlow(tint, radius: theme.glowRadius(6) + abs(sin(t * 4)) * 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .rainbow:
            label
                .foregroundStyle(
                    LinearGradient(colors: (0..<7).map {
                        Color(hue: (t * 0.12 + Double($0) / 7).truncatingRemainder(dividingBy: 1),
                              saturation: 0.85, brightness: 1)
                    }, startPoint: .leading, endPoint: .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
