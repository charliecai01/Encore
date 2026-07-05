import SwiftUI
import WebKit
import EncoreCore

/// Manages the in-app Google sign-in. Cookies live in WKWebsiteDataStore.default()
/// (shared with the playback web view, so Premium applies there too) and are
/// mirrored into InnerTube's Cookie header for API calls.
@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isSignedIn = false
    @Published var showLogin = false

    private init() {}

    func bootstrap() async {
        await refresh()
    }

    func refresh() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let relevant = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let hasAuth = relevant.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }

        InnerTube.shared.cookieHeader = header.isEmpty ? nil : header
        if isSignedIn != hasAuth {
            isSignedIn = hasAuth
        }
    }

    /// Fallback sign-in: import a raw Cookie header copied from the user's
    /// real browser (DevTools → any music.youtube.com request → cookie header).
    /// Injecting into the shared WKWebsiteDataStore signs in both the API and
    /// the playback web view.
    func importCookies(_ raw: String) async -> Bool {
        let store = WKWebsiteDataStore.default().httpCookieStore
        var header = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate pasting a full "Copy as cURL" command: take what follows
        // "cookie:" and stop at the quote/newline that ends the header value.
        if let range = header.range(of: "cookie:", options: [.caseInsensitive]) {
            header = String(header[range.upperBound...])
        }
        if let end = header.firstIndex(where: { $0 == "'" || $0 == "\"" || $0.isNewline }) {
            header = String(header[..<end])
        }
        var count = 0
        for part in header.components(separatedBy: ";") {
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            let name = String(pair[..<eq])
            let value = String(pair[pair.index(after: eq)...])
            guard let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".youtube.com",
                .path: "/",
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(3600 * 24 * 365 * 2),
            ]) else { continue }
            await store.setCookie(cookie)
            count += 1
        }
        guard count > 0 else { return false }
        await refresh()
        if isSignedIn {
            PlayerEngine.shared.reloadSite()
            LibraryStore.shared.invalidate()
        }
        return isSignedIn
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let targets = records.filter {
            $0.displayName.contains("google") || $0.displayName.contains("youtube")
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets)
        InnerTube.shared.cookieHeader = nil
        isSignedIn = false
        LibraryStore.shared.invalidate()
    }

    static var loginURL: URL {
        var comps = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        comps.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "continue", value: "https://music.youtube.com/"),
        ]
        return comps.url!
    }
}

struct LoginSheet: View {
    @EnvironmentObject var auth: AuthManager

    @State private var pasteMode = false
    @State private var cookieText = ""
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pasteMode ? "Import browser session" : "Sign in to YouTube Music")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    Task {
                        await auth.refresh()
                        auth.showLogin = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            if pasteMode {
                pasteView
            } else {
                LoginWebView()
                Divider()
                Button("Sign-in not working? Import cookies from your browser instead") {
                    pasteMode = true
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(10)
            }
        }
        .frame(width: 540, height: 700)
    }

    private var pasteView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("In your normal browser (Chrome/Safari), while signed in:")
                    .font(.system(size: 13, weight: .semibold))
                Text("""
                1. Open music.youtube.com
                2. Open DevTools (⌥⌘I) → Network tab, then reload the page
                3. Click any request to music.youtube.com
                4. Under Request Headers, copy the entire "cookie:" value
                5. Paste it below
                """)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
            }

            TextEditor(text: $cookieText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))

            if let importError {
                Text(importError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Back to Google sign-in") {
                    pasteMode = false
                    importError = nil
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                Spacer()
                Button("Import") {
                    Task {
                        let ok = await auth.importCookies(cookieText)
                        if ok {
                            auth.showLogin = false
                        } else {
                            importError = "That didn't contain a valid YouTube session — make sure you copied the whole cookie header (it should include SAPISID)."
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct LoginWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        // Google blocks sign-in from browsers it considers outdated or
        // embedded. WKWebView is Safari's engine, so the current Safari UA is
        // truthful and indistinguishable — but the Version/ token must be
        // recent or Google silently rejects the email step.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: AuthManager.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkSignedIn(webView)
        }

        func webView(_ webView: WKWebView,
                     didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            checkSignedIn(webView)
        }

        // Google's flow sometimes targets a new window (popup/`_blank`); load
        // those in the same view instead of dropping them on the floor.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Re-route window-targeted navigations into this view.
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        private func checkSignedIn(_ webView: WKWebView) {
            guard let host = webView.url?.host,
                  host.contains("music.youtube.com") || host.contains("www.youtube.com") else { return }
            Task { @MainActor in
                await AuthManager.shared.refresh()
                if AuthManager.shared.isSignedIn {
                    AuthManager.shared.showLogin = false
                    LibraryStore.shared.invalidate()
                }
            }
        }
    }
}

/// Caches library playlists (sidebar) and liked songs (library + artist pages).
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var playlists: [CardItem] = []
    /// Subscribed podcast shows, pinned atop the sidebar playlists (TheMove
    /// is the only feed in use — one click beats Library → Podcasts).
    @Published var podcastShows: [CardItem] = []
    private var loaded = false
    private var songsCache: [Track]?
    private var songsTask: Task<[Track], Never>?
    private var allTracksCache: [Track]?
    private var allTracksTask: Task<[Track], Never>?

    private init() {}

    // MARK: - Custom sidebar playlist order (local-only; YT Music has no
    // server-side list order). Persisted as an id array; playlists missing
    // from it (newly created) stay at the top in server order.

    private static let orderKey = "sidebarPlaylistOrder"

    private func cardId(_ c: CardItem) -> String { c.playlistId ?? c.id }

    func applyCustomOrder(_ cards: [CardItem]) -> [CardItem] {
        let saved = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        guard !saved.isEmpty else { return cards }
        var byId: [String: CardItem] = [:]
        for c in cards { byId[cardId(c)] = c }
        var ordered: [CardItem] = []
        for id in saved {
            if let c = byId.removeValue(forKey: id) { ordered.append(c) }
        }
        let newOnes = cards.filter { byId[cardId($0)] != nil }
        return newOnes + ordered
    }

    /// Drag-to-reorder: move `draggedId` so it sits before `targetId`, and
    /// persist the full resulting order.
    func movePlaylist(_ draggedId: String, before targetId: String) {
        guard draggedId != targetId else { return }
        var ids = playlists.map(cardId)
        guard let from = ids.firstIndex(of: draggedId) else { return }
        ids.remove(at: from)
        let to = ids.firstIndex(of: targetId) ?? ids.count
        ids.insert(draggedId, at: to)
        UserDefaults.standard.set(ids, forKey: Self.orderKey)
        var byId: [String: CardItem] = [:]
        for c in playlists { byId[cardId(c)] = c }
        playlists = ids.compactMap { byId[$0] }
    }

    func loadIfNeeded() async {
        guard !loaded, AuthManager.shared.isSignedIn else { return }
        loaded = true
        playlists = applyCustomOrder((try? await YTM.shared.libraryPlaylists()) ?? [])
        if PodcastFeature.enabled {
            podcastShows = ((try? await YTM.shared.libraryPodcasts()) ?? [])
                .filter { $0.kind == .podcast }
        }
        // Warm the liked library so hearts are correct app-wide, not only
        // after visiting a library page.
        Task { _ = await self.songs() }
    }

    /// All liked/library songs, fetched once per session and deduplicated
    /// across concurrent callers.
    func songs(forceRefresh: Bool = false) async -> [Track] {
        guard AuthManager.shared.isSignedIn else { return [] }
        if !forceRefresh, let songsCache { return songsCache }
        if !forceRefresh, let songsTask { return await songsTask.value }
        let task = Task<[Track], Never> {
            (try? await YTM.shared.librarySongs()) ?? []
        }
        songsTask = task
        let result = await task.value
        songsCache = result
        songsTask = nil
        // Seed liked state so hearts and "Remove from Liked" are correct for
        // songs liked in past sessions, not just this one.
        PlayerEngine.shared.likedIds.formUnion(result.map(\.videoId))
        return result
    }

    /// Liked songs plus the contents of every library playlist, deduplicated.
    /// Disk-cached across launches (instant), refreshed in the background once
    /// per session. Playlist pages land in PageCache as a side effect, so
    /// those playlists open instantly too.
    private var allTracksRefreshed = false

    func allKnownTracks() async -> [Track] {
        guard AuthManager.shared.isSignedIn else { return [] }
        if allTracksCache == nil,
           let saved = DiskCache.load([Track].self, from: "library-tracks.json"),
           !saved.isEmpty {
            allTracksCache = saved
        }
        if let allTracksCache {
            if !allTracksRefreshed {
                allTracksRefreshed = true
                Task {
                    let fresh = await self.fetchAllKnownTracks()
                    if !fresh.isEmpty {
                        self.allTracksCache = fresh
                        DiskCache.save(fresh, as: "library-tracks.json")
                    }
                }
            }
            return allTracksCache
        }
        if let allTracksTask { return await allTracksTask.value }
        let task = Task<[Track], Never> { await fetchAllKnownTracks() }
        allTracksTask = task
        let result = await task.value
        allTracksCache = result
        allTracksTask = nil
        allTracksRefreshed = true
        if !result.isEmpty {
            DiskCache.save(result, as: "library-tracks.json")
        }
        return result
    }

    private func fetchAllKnownTracks() async -> [Track] {
        var all = await songs()
        await loadIfNeeded()
        var seenIds = Set<String>()
        let ids = playlists.compactMap(\.playlistId)
            .filter { $0 != "LM" && !$0.hasPrefix("RD") && seenIds.insert($0).inserted }

        for chunk in ids.chunks(of: 4) {
            await withTaskGroup(of: (String, CollectionPage?).self) { group in
                for id in chunk {
                    group.addTask {
                        (id, try? await YTM.shared.playlist(id: id))
                    }
                }
                for await (id, page) in group {
                    guard let page else { continue }
                    PageCache.shared.collections["playlist-\(id)"] = page
                    all.append(contentsOf: page.tracks)
                }
            }
        }

        var seen = Set<String>()
        return all.filter { seen.insert($0.videoId).inserted }
    }

    private var discoverCache: [Track]?

    /// Client-side "Discover": fresh tracks (excluding everything you already
    /// know + recent history), biased to the opposite language of your taste.
    func discover() async -> [Track] {
        guard AuthManager.shared.isSignedIn else { return [] }
        if let discoverCache { return discoverCache }
        let known = await allKnownTracks()
        guard known.count >= 3 else { return [] }
        var exclude = Set(known.map(\.videoId))
        if let history = try? await YTM.shared.history() {
            exclude.formUnion(history.flatMap(\.tracks).map(\.videoId))
        }
        let seeds = Array(known.shuffled().prefix(12)).map(\.videoId)
        let pool = await YTM.shared.discoverPool(seeds: seeds)
        let result = Discovery.curate(candidates: pool, exclude: exclude,
                                      preferNonCJK: Discovery.cjkFraction(known) > 0.5, limit: 40)
        discoverCache = result
        return result
    }

    func invalidate() {
        loaded = false
        playlists = []
        songsCache = nil
        songsTask = nil
        allTracksCache = nil
        allTracksTask = nil
        allTracksRefreshed = false
        discoverCache = nil
        PageCache.shared.clear()
        Task { await loadIfNeeded() }
    }
}

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
