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
                }

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
