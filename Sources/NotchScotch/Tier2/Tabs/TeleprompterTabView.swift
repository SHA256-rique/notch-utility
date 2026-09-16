import SwiftUI
import AppKit

/// Teleprompter: write the script here, drive the always-on-top window from
/// here.
///
/// ## Why this tab exists
/// The feature was already built, and effectively invisible: the only ways in
/// were a status-bar menu item and a section four scrolls down inside Settings.
/// A feature nobody can find is a feature that does not exist, and the two
/// things it needs -- somewhere to write a script, and controls to run it --
/// are exactly what a tab is for.
///
/// ## The prompter window is separate on purpose
/// The script is composed here; the words are displayed in a borderless
/// always-on-top window that can sit over whatever you are presenting, be
/// mirrored for a beam-splitter rig, and be hidden from screen recording. That
/// window has to outlive this tab -- you close the panel and keep reading -- so
/// it is owned by `TeleprompterController`, not by this view.
struct TeleprompterTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var controller = TeleprompterController.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let theme = themes.theme
        HStack(spacing: 0) {
            editor(theme)
                .frame(maxWidth: .infinity)

            Divider().overlay(theme.panelStroke)

            controls(theme)
                .frame(width: 244)
        }
    }

    // MARK: - Script

    private func editor(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                NBSectionHeader(title: "Script", trailing: stats)
                Button("Paste") { paste() }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                Button("Clear") {
                    controller.script = ""
                    controller.persist()
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                .disabled(controller.script.isEmpty)
            }
            .padding(.horizontal, 12).padding(.top, 10)

            TextEditor(text: Binding(
                get: { controller.script },
                set: { controller.script = $0; controller.persist() }))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    /// Word count and an estimated read time. 140 words per minute is the
    /// figure broadcast training uses for scripted delivery -- conversational
    /// speech is faster, but nobody reads a teleprompter conversationally.
    private var stats: String {
        let words = controller.script.split { $0.isWhitespace || $0.isNewline }.count
        guard words > 0 else { return "empty" }
        let seconds = Int(Double(words) / 140.0 * 60)
        return "\(words) words · about \(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: - Controls

    private func controls(_ theme: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                NBCard(tint: .message, padding: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            NBSectionHeader(title: "Prompter window")
                            Circle()
                                .fill(controller.isOpen ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                        }

                        Button {
                            controller.isOpen ? controller.close() : controller.open()
                        } label: {
                            Label(controller.isOpen ? "Close window" : "Open window",
                                  systemImage: controller.isOpen ? "xmark.rectangle" : "rectangle.on.rectangle")
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.message), filled: !controller.isOpen))

                        HStack(spacing: 5) {
                            Button {
                                controller.isRunning ? controller.stop() : controller.start()
                            } label: {
                                Label(controller.isRunning ? "Pause" : "Play",
                                      systemImage: controller.isRunning ? "pause.fill" : "play.fill")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.message),
                                                       filled: !controller.isRunning, compact: true))
                            .disabled(!controller.isOpen || controller.script.isEmpty)

                            Button {
                                controller.reset()
                            } label: {
                                Label("Top", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                            .disabled(!controller.isOpen)
                        }

                        if controller.countdown > 0 {
                            Text("Starting in \(controller.countdown)…")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.tint(.message))
                        }

                        if !controller.isOpen {
                            Text("Open the window first — it is the thing that shows the words.")
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                NBCard(tint: .message, padding: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        NBSectionHeader(title: "Pace")
                        labelled("Speed", "\(Int(controller.speed)) pt/s", theme)
                        Slider(value: Binding(
                            get: { controller.speed },
                            set: { controller.speed = $0; controller.persist() }),
                               in: 10...140, step: 5)
                            .controlSize(.mini)
                        Text("Set it once, then adjust while reading — the window keeps scrolling at whatever you leave it on.")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        labelled("Text size", "\(Int(controller.fontSize)) pt", theme)
                        Slider(value: Binding(
                            get: { controller.fontSize },
                            set: { controller.fontSize = $0; controller.persist() }),
                               in: 18...72, step: 2)
                            .controlSize(.mini)
                    }
                }

                NBCard(tint: .message, padding: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        NBSectionHeader(title: "Presentation")

                        Toggle("Mirror horizontally", isOn: Binding(
                            get: { controller.isMirrored },
                            set: { controller.isMirrored = $0; controller.persist() }))
                            .font(.system(size: 11)).toggleStyle(.checkbox)
                        Text("For a beam-splitter rig, where the text is reflected off glass in front of the lens.")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider().overlay(theme.panelStroke)

                        Toggle("Hide from screen recording", isOn: Binding(
                            get: { settings.data.hideFromScreenRecordingTeleprompter },
                            set: {
                                settings.data.hideFromScreenRecordingTeleprompter = $0
                                controller.hideFromCapture = $0
                                controller.applyCaptureHiding()
                            }))
                            .font(.system(size: 11)).toggleStyle(.checkbox)
                        Text("On by default, and the reason this feature is usable at all: the window sits over your call, but everyone on the other end sees what is behind it. It sets NSWindow.sharingType to .none, which excludes it from ScreenCaptureKit and from Shift-Cmd-4.")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        if !settings.data.hideFromScreenRecordingTeleprompter {
                            Label("Your script will appear in recordings and screen shares.",
                                  systemImage: "eye.trianglebadge.exclamationmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("The prompter window is borderless, always on top, and draggable by its background. It stays open when you close this panel.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }

    private func labelled(_ title: String, _ value: String, _ theme: Theme) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(theme.primaryText)
            Spacer()
            Text(value).font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        controller.script = controller.script.isEmpty ? text : controller.script + "\n\n" + text
        controller.persist()
    }
}
