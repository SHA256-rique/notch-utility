import SwiftUI
import AppKit

/// Word of the day, as a rail down the side of the whole panel.
///
/// ## Why a rail and not a tile
/// It was a Home tile, which meant you saw the word only if you happened to
/// open Home. A word you have to go looking for is not a word a day — the whole
/// mechanism depends on it being in front of you without being asked for.
///
/// A rail is the shape that fits: it is present on every tab, it costs 190pt of
/// a fixed-width panel, and it collapses to a 22pt strip when a tab needs the
/// room. The strip still shows the language badge, so the feature never
/// vanishes entirely — a collapsed rail you cannot find again is just an off
/// switch with extra steps.
struct WordRailView: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var controller: NotchPanelController
    @ObservedObject private var service = DailyWordService.shared
    @ObservedObject private var settings = Settings.shared

    static let width: CGFloat = 190
    static let collapsedWidth: CGFloat = 22

    var body: some View {
        let theme = themes.theme
        if settings.data.wordRailExpanded {
            expanded(theme)
                .frame(width: Self.width)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            collapsed(theme)
                .frame(width: Self.collapsedWidth)
        }
    }

    // MARK: - Collapsed strip

    private func collapsed(_ theme: Theme) -> some View {
        let word = service.todaysWords.first
        return VStack(spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.secondaryText)
            if let word {
                Text(word.language.code)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.tint(.notes))
            }
            Text("WORD")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(theme.secondaryText)
                // Rotated rather than one letter per line: a vertical stack of
                // characters reads as a ransom note, a rotated word reads as a
                // label on a spine.
                .rotationEffect(.degrees(90))
                .fixedSize()
                .frame(height: 44)
            Spacer()
        }
        .padding(.top, 8)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.panelStroke).frame(width: 0.5)
        }
        .contentShape(Rectangle())
        .pointerCursor()
        .onTapGesture {
            withAnimation(Motion.sheet) { settings.data.wordRailExpanded = true }
        }
        .help(word.map { "\($0.term) — \($0.meaning)" } ?? "Word of the day")
    }

    // MARK: - Expanded rail

    private func expanded(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                NBSectionHeader(title: service.isShowingToday ? "Word of the day" : "Word")
                Button {
                    withAnimation(Motion.sheet) { settings.data.wordRailExpanded = false }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain).pointerCursor()
                .foregroundStyle(theme.secondaryText)
                .help("Collapse")
            }
            .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 4)

            if service.todaysWords.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No languages selected.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    Button("Choose languages") {
                        controller.openTab(.builtin(.settings))
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), compact: true))
                }
                .padding(.horizontal, 10)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(service.todaysWords) { word in
                            card(word, theme)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }

                footer(theme)
            }
        }
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.panelStroke).frame(width: 0.5)
        }
    }

    private func card(_ word: WordEntry, _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(word.language.code)
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(theme.tint(.notes).opacity(0.22)))
                    .foregroundStyle(theme.tint(.notes))
                Text(word.partOfSpeech)
                    .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                Spacer()
                Button {
                    service.speak(word)
                } label: { Image(systemName: "speaker.wave.2.fill").font(.system(size: 8)) }
                    .buttonStyle(.plain).pointerCursor()
                    .foregroundStyle(theme.secondaryText)
                    .help("Hear it")
                Button {
                    service.toggleLearned(word)
                } label: {
                    Image(systemName: service.isLearned(word) ? "checkmark.seal.fill" : "seal")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain).pointerCursor()
                .foregroundStyle(service.isLearned(word) ? theme.tint(.notes) : theme.secondaryText)
                .help(service.isLearned(word) ? "Marked as learned" : "Mark as learned")
            }

            Text(word.term)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2).minimumScaleFactor(0.7)

            if !word.pronunciation.isEmpty {
                Text(word.pronunciation)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }

            Text(word.meaning)
                .font(.system(size: 10))
                .foregroundStyle(theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            if settings.data.dailyWord.showExample {
                Text(word.example)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(theme.tint(.notes).opacity(0.5)).frame(width: 2)
                    }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.cardBackground))
    }

    private func footer(_ theme: Theme) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Button {
                    service.previousWord()
                } label: { Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                    .help("Previous word")

                Button {
                    service.nextWord()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), compact: true))
                .help("Another word")

                Spacer()

                if !service.isShowingToday {
                    Button("Today") { service.backToToday() }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), filled: true, compact: true))
                }
            }

            Button {
                controller.openDetail(.dailyWord)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "books.vertical").font(.system(size: 9))
                    Text("Glossary")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text("\(service.glossaryCount)")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                }
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), compact: true))

            if service.streak > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.system(size: 8))
                    Text("\(service.streak) day streak")
                        .font(.system(size: 9, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 9).padding(.top, 2)
    }
}
