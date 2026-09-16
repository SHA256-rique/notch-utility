import SwiftUI
import WebKit

/// Renders a user-configured custom tab.
///
/// The whole point of the config-driven approach: this is a `switch` over four
/// shipped types, each of which is ordinary app code that we wrote and audited.
/// There is no bundle loading, no script engine, no dynamic code path. A user
/// "adding a tab" adds a row of configuration, not a new executable surface.
struct CustomTabView: View {
    let config: CustomTabConfig
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        switch config.kind {
        case .webView:     CustomWebTab(config: config)
        case .launcher:    CustomLauncherTab(config: config)
        case .snippetList: CustomSnippetTab(config: config)
        case .metric:      CustomMetricTab(config: config)
        }
    }
}

/// A pinned web page.
///
/// `WKWebView` is created on appear and **explicitly torn down** on disappear --
/// `loadHTMLString("")` then dropping the reference. A WKWebView that stays
/// alive keeps its own content process running, which is tens of megabytes and
/// its own timers; leaving one resident would undo a large part of this app's
/// memory story on its own.
struct CustomWebTab: View {
    let config: CustomTabConfig
    @EnvironmentObject private var themes: ThemeManager
    @State private var isLoaded = false

    var body: some View {
        Group {
            // Normalised at render time as well as at save time, so a tab
            // created before bare domains were accepted still loads instead of
            // showing an empty state forever.
            if let url = URL(string: CustomTabConfig.normalisedURL(config.url)),
               url.scheme?.hasPrefix("http") == true, url.host != nil {
                WebViewContainer(url: url, isLoaded: $isLoaded)
            } else {
                NBEmptyState(symbol: "globe", title: "No address set",
                             subtitle: "Edit this tab in Settings → Tabs and give it an address. A bare domain like google.com is fine.")
            }
        }
    }
}

struct WebViewContainer: NSViewRepresentable {
    let url: URL
    @Binding var isLoaded: Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent data store: no cookies, cache or local storage survive
        // the tab closing. A pinned dashboard should not quietly accumulate
        // tracking state inside a utility app.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url { nsView.load(URLRequest(url: url)) }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        // Stop everything the page is doing before the view is released.
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
    }
}

struct CustomLauncherTab: View {
    let config: CustomTabConfig
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let theme = themes.theme
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(config.shortcutPaths, id: \.self) { path in
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        NotchPanelController.shared.collapse()
                    } label: {
                        VStack(spacing: 3) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 34, height: 34)
                            Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                .font(.system(size: 8)).lineLimit(1)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            if config.shortcutPaths.isEmpty {
                NBEmptyState(symbol: "square.grid.2x2", title: "No shortcuts yet",
                             subtitle: "Add apps to this tab in Settings → Custom tabs.")
            }
        }
    }
}

struct CustomSnippetTab: View {
    let config: CustomTabConfig
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var store = SnippetStore.shared
    @State private var query = ""

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 6) {
            NBTextField(placeholder: "Search…", text: $query)
                .padding(.horizontal, 12).padding(.top, 8)
            let results = store.filtered(query: query, source: nil, pinnedOnly: false,
                                         tag: config.snippetTagFilter)
            if results.isEmpty {
                NBEmptyState(symbol: "text.badge.star", title: "Nothing tagged “\(config.snippetTagFilter)”")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { snippet in
                            Button { store.touch(snippet.id) } label: {
                                HStack {
                                    Text(snippet.displayTitle)
                                        .font(.system(size: 11)).lineLimit(1)
                                        .foregroundStyle(theme.primaryText)
                                    Spacer()
                                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }
}

struct CustomMetricTab: View {
    let config: CustomTabConfig
    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var fetcher: MetricFetcher

    init(config: CustomTabConfig) {
        self.config = config
        _fetcher = StateObject(wrappedValue: MetricFetcher(config: config))
    }

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 8) {
            Spacer()
            switch fetcher.state {
            case .value(let text):
                Text(text)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .minimumScaleFactor(0.4).lineLimit(1)
                Text(config.title).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                if let updated = fetcher.lastUpdated {
                    Text("updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.7))
                }
            case .loading, .idle:
                ProgressView().controlSize(.small)
            case .failed(let message):
                NBEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load", subtitle: message)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { fetcher.activate() }
        .onDisappear { fetcher.deactivate() }
    }
}
