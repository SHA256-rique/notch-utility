import SwiftUI
import AppKit

/// Settings → Widgets. Everything the Home-grid tiles need in order to be
/// something other than an empty box: the Stripe key behind Revenue, the
/// analytics endpoint behind Visitors, the language choice behind Word of the
/// Day, and the water reminder's schedule.
///
/// All three secrets go to Keychain and never to `settings.json`. The panes
/// check `Keychain.has(...)` to report status rather than reading the secret
/// back, so the key is not pulled into the process just to render a checkmark.
struct WidgetSettings: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        RevenueSettingsSection()
        VisitorsSettingsSection()
        CalendarSettingsSection()
        WordSettingsSection()
        WaterSettingsSection()
    }
}

// MARK: - Revenue

struct RevenueSettingsSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @State private var keyDraft = ""
    @State private var hasKey = Keychain.has(StripeClient.keychainAccount)

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Revenue (Stripe)",
                        trailing: hasKey ? "key stored" : "not connected")
        NBCard(tint: .api, padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Use a **restricted** key with read access to Charges. A full secret key would work and would also let anything that reads your Keychain issue refunds.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    SecureField(hasKey ? "•••••••• stored in Keychain" : "rk_live_… or sk_test_…",
                                text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

                    Button("Save") {
                        Keychain.set(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                     for: StripeClient.keychainAccount)
                        keyDraft = ""
                        hasKey = Keychain.has(StripeClient.keychainAccount)
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.api), filled: true, compact: true))
                    .disabled(keyDraft.isEmpty)

                    if hasKey {
                        Button("Remove") {
                            Keychain.delete(StripeClient.keychainAccount)
                            hasKey = false
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                    }
                }

                HStack(spacing: 6) {
                    Text("Endpoint").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        .frame(width: 60, alignment: .leading)
                    NBTextField(placeholder: "https://api.stripe.com/v1",
                                text: $settings.data.stripe.apiBase, monospaced: true)
                }
                HStack(spacing: 6) {
                    Text("Symbol").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        .frame(width: 60, alignment: .leading)
                    NBTextField(placeholder: "$", text: $settings.data.stripe.currencySymbol)
                        .frame(width: 60)
                    Toggle("Count refunded charges", isOn: $settings.data.stripe.includeRefunded)
                        .font(.system(size: 10)).toggleStyle(.checkbox)
                    Spacer()
                }

                Text("Point the endpoint at your own proxy if you would rather not keep a Stripe key on a laptop at all — the widget only needs something that answers Stripe's /charges shape.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Visitors

struct VisitorsSettingsSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @State private var tokenDraft = ""
    @State private var hasToken = Keychain.has(VisitorsService.keychainAccount)
    @State private var showPaths = false

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Visitors",
                        trailing: settings.data.homeWidgets.contains(.visitors) ? "on your grid" : "add it from Edit widgets")
        NBCard(tint: .docker, padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                FlowRow(spacing: 5) {
                    ForEach(VisitorsService.presets) { preset in
                        Button(preset.name) { apply(preset) }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.docker), compact: true))
                            .help(preset.hint)
                    }
                }

                NBTextField(placeholder: "https://plausible.io/api/v1/stats/aggregate?site_id=…",
                            text: $settings.data.visitors.url, monospaced: true)

                HStack(spacing: 6) {
                    SecureField(hasToken ? "•••••••• stored in Keychain" : "API token (sent as a Bearer header)",
                                text: $tokenDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                    Button("Save") {
                        Keychain.set(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                     for: VisitorsService.keychainAccount)
                        tokenDraft = ""
                        hasToken = Keychain.has(VisitorsService.keychainAccount)
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.docker), filled: true, compact: true))
                    .disabled(tokenDraft.isEmpty)
                    if hasToken {
                        Button("Remove") {
                            Keychain.delete(VisitorsService.keychainAccount)
                            hasToken = false
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                    }
                }

                Button(showPaths ? "Hide JSON paths" : "Edit JSON paths") {
                    withAnimation(Motion.sheet) { showPaths.toggle() }
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))

                if showPaths {
                    pathField("Count", $settings.data.visitors.currentPath, theme)
                    pathField("Previous", $settings.data.visitors.previousPath, theme)
                    pathField("Series", $settings.data.visitors.seriesPath, theme)
                    pathField("Series value", $settings.data.visitors.seriesValuePath, theme)
                    Text("Dot paths into the response. Numeric components index arrays, so results.0.visitors works. Leave 'Previous' empty if your endpoint does not return a comparison — the change badge simply won't show.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func pathField(_ label: String, _ binding: Binding<String>, _ theme: Theme) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                .frame(width: 80, alignment: .leading)
            NBTextField(placeholder: "path.to.value", text: binding, monospaced: true)
        }
    }

    private func apply(_ preset: VisitorsService.Preset) {
        settings.data.visitors.currentPath = preset.currentPath
        settings.data.visitors.previousPath = preset.previousPath
        settings.data.visitors.seriesPath = preset.seriesPath
        settings.data.visitors.seriesValuePath = preset.seriesValuePath
        showPaths = true
    }
}

// MARK: - Word of the day

struct WordSettingsSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var service = DailyWordService.shared

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Word of the day",
                        trailing: "\(service.learnedCount) learned")
        NBCard(tint: .notes, padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Pick one or more languages. Each gets its own card, and the word changes at your local midnight — not on a schedule the app has to be running for.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                FlowRow(spacing: 5) {
                    ForEach(WordLanguage.allCases) { language in
                        let on = settings.data.dailyWord.languages.contains(language.rawValue)
                        Button {
                            toggle(language)
                        } label: {
                            HStack(spacing: 4) {
                                Text(language.code)
                                    .font(.system(size: 9, weight: .bold))
                                Text(language.displayName).font(.system(size: 10))
                            }
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), filled: on, compact: true))
                        .help("\(service.totalWords(for: language)) words")
                    }
                }

                Toggle("Show an example sentence", isOn: $settings.data.dailyWord.showExample)
                    .font(.system(size: 10)).toggleStyle(.checkbox)
            }
        }
    }

    private func toggle(_ language: WordLanguage) {
        var languages = settings.data.dailyWord.languages
        if let index = languages.firstIndex(of: language.rawValue) {
            languages.remove(at: index)
        } else {
            languages.append(language.rawValue)
        }
        settings.data.dailyWord.languages = languages
    }
}

// MARK: - Water

struct WaterSettingsSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Drink water")
        NBCard(tint: .time, padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Nudge me to drink").font(.system(size: 11))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.data.waterNudgesEnabled },
                        set: { WaterTracker.shared.setNudges(enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                HStack(spacing: 8) {
                    Text("Every \(Int(settings.data.waterIntervalMinutes)) min")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(theme.secondaryText).frame(width: 90, alignment: .leading)
                    Slider(value: Binding(
                        get: { settings.data.waterIntervalMinutes },
                        set: { WaterTracker.shared.setInterval(minutes: $0) }),
                           in: 15...180, step: 5)
                        .controlSize(.mini)
                }
                Stepper("Daily goal: \(settings.data.waterGlassGoal) glasses",
                        value: $settings.data.waterGlassGoal, in: 1...20)
                    .font(.system(size: 10))
            }
        }
    }
}


// MARK: - Calendar

struct CalendarSettingsSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @StateObject private var google = GoogleCalendarService()
    @State private var secretDraft = ""
    @State private var hasSecret = Keychain.has(GoogleCalendarService.clientSecretAccount)

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Calendar sources")
        NBCard(tint: .calendar, padding: 9) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use the Mac's own calendars (EventKit)",
                       isOn: $settings.data.calendarUseAppleEventKit)
                    .font(.system(size: 11)).toggleStyle(.checkbox)

                Divider().overlay(theme.panelStroke)

                Toggle("Link Google Calendar directly", isOn: $settings.data.calendarUseGoogle)
                    .font(.system(size: 11)).toggleStyle(.checkbox)

                Text("Linking Google here does not add an account to macOS. The grant is read-only and covers calendars alone — not your mail or contacts — and you can revoke it from your Google account page at any time.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.data.calendarUseGoogle {
                    NBTextField(placeholder: "OAuth client ID (…apps.googleusercontent.com)",
                                text: $settings.data.googleOAuthClientID, monospaced: true)

                    HStack(spacing: 6) {
                        SecureField(hasSecret ? "•••••••• stored in Keychain"
                                              : "Client secret (Desktop app clients have one)",
                                    text: $secretDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                        Button("Save") {
                            Keychain.set(secretDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                         for: GoogleCalendarService.clientSecretAccount)
                            secretDraft = ""
                            hasSecret = Keychain.has(GoogleCalendarService.clientSecretAccount)
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), filled: true, compact: true))
                        .disabled(secretDraft.isEmpty)
                    }

                    GoogleConnectButton(service: google)

                    if case .failed(let message) = google.state {
                        Text(message).font(.system(size: 9)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("SETUP").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(theme.secondaryText)
                        step(1, "In Google Cloud Console, create a project (or pick one).", theme)
                        step(2, "APIs & Services → Library → enable **Google Calendar API**.", theme)
                        step(3, "APIs & Services → Credentials → Create credentials → OAuth client ID.", theme)
                        step(4, "Application type: **Desktop app**. Not Web application — a desktop client needs no redirect URL, and a web client cannot use the loopback port this flow picks at runtime.", theme)
                        step(5, "Copy the client ID (and the secret, if shown) into the fields above.", theme)
                        HStack(spacing: 6) {
                            Button("Open Google Cloud Credentials") {
                                NSWorkspace.shared.open(URL(string:
                                    "https://console.cloud.google.com/apis/credentials")!)
                            }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                            Button("Enable Calendar API") {
                                NSWorkspace.shared.open(URL(string:
                                    "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!)
                            }
                            .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                        }
                        .padding(.top, 2)
                    }

                    Text("There is no URL to paste anywhere. Sign-in opens your browser and catches the reply on a loopback port this app opens for one request, protected by PKCE — so the \"secret\" is not treated as one, and the code exchange is guarded by a verifier that never leaves this Mac.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { google.activate() }
    }

    private func step(_ number: Int, _ text: String, _ theme: Theme) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("\(number)")
                .font(.system(size: 8, weight: .bold)).monospacedDigit()
                .frame(width: 13, height: 13)
                .background(Circle().fill(theme.tint(.calendar).opacity(0.25)))
                .foregroundStyle(theme.tint(.calendar))
            Text(.init(text))
                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
