import SwiftUI

/// Message tab: composes a flash-across-the-notch banner.
///
/// The "Sent before" chips come straight out of `SnippetStore`, which is the
/// payoff for unifying clipboard/saved/pinned into one store -- this feature
/// needed a "things I have sent" list and got it for free.
struct MessageTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var flash = FlashMessageController.shared
    @ObservedObject private var store = SnippetStore.shared

    var body: some View {
        let theme = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                NBSectionHeader(title: "Flash a message")

                HStack(spacing: 6) {
                    NBTextField(placeholder: "Type something to flash across the notch…",
                                text: $flash.text) { flash.flash() }
                    Button(flash.isShowing ? "Take it down" : "Flash it") {
                        flash.isShowing ? flash.takeDown() : flash.flash()
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.message), filled: !flash.isShowing))
                    if flash.isShowing && flash.autoTakeDown {
                        Button("+10s") { flash.extend() }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.message), compact: true))
                    }
                }

                HStack(spacing: 10) {
                    Toggle("Take it down automatically", isOn: $flash.autoTakeDown)
                        .font(.system(size: 10)).toggleStyle(.checkbox)
                    if flash.autoTakeDown {
                        Text("after \(Int(flash.autoTakeDownSeconds))s")
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                        Slider(value: $flash.autoTakeDownSeconds, in: 3...60, step: 1)
                            .controlSize(.mini).frame(width: 120)
                    }
                    Spacer()
                    if flash.isShowing {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text(flash.autoTakeDown
                                 ? "on screen · \(flash.secondsRemaining)s left"
                                 : "on screen")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(theme.tint(.message))
                        }
                    }
                }
                Text("A banner is a full-width strip across the top of your display. Leaving one up by accident means it is still there during your next screen share — which is why it takes itself down by default.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                NBSectionHeader(title: "Style")
                FlowRow(spacing: 6) {
                    ForEach(FlashStyle.allCases) { style in
                        Button {
                            flash.style = style
                        } label: {
                            Label(style.displayName, systemImage: style.symbol)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.message),
                                                   filled: flash.style == style, compact: true))
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Speed  \(String(format: "%.2fx", flash.speed))")
                            .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        Slider(value: $flash.speed, in: 0.25...3)
                            .controlSize(.mini).frame(width: 160)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Use theme colour", isOn: $flash.useThemeColor)
                            .font(.system(size: 10)).toggleStyle(.checkbox)
                        if !flash.useThemeColor {
                            ColorPicker("", selection: $flash.color).labelsHidden()
                        }
                    }
                    Spacer()
                }

                if !store.recentlyUsedText.isEmpty {
                    NBSectionHeader(title: "Sent before")
                    FlowRow(spacing: 6) {
                        ForEach(store.recentlyUsedText) { snippet in
                            Button {
                                flash.text = snippet.payload.asText
                                flash.flash()
                            } label: {
                                Text(snippet.displayTitle)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .frame(maxWidth: 160)
                            }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.snippets), compact: true))
                        }
                    }
                }

                Text("The banner is click-through, so it never gets in the way of what's underneath.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            }
            .padding(12)
        }
    }
}
