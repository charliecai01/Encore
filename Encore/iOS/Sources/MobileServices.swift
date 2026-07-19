import SwiftUI
import WebKit
import EncoreCore

// MARK: - Theme

enum Theme {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.075)
    static let bgElevated = Color(red: 0.09, green: 0.09, blue: 0.115)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.09)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let accent = Color(red: 1.0, green: 0.32, blue: 0.38)
}

// MARK: - Disk cache

enum DiskCache {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Encore", isDirectory: true)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name))
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

@MainActor
final class PageCache {
    static let shared = PageCache()

    var collections: [String: CollectionPage] = [:] { didSet { persistCollectionsSoon() } }
    var artists: [String: ArtistPage] = [:]
    // Home feed + the quick-access playlist grid, persisted to disk so the Home
    // tab renders instantly on a cold launch instead of waiting on the network.
    var shelves: [String: [Shelf]] = [:] { didSet { persistHomeSoon() } }
    var homePlaylists: [CardItem] = [] { didSet { persistHomeSoon() } }

    private var collectionsTask: Task<Void, Never>?
    private var homeTask: Task<Void, Never>?

    private struct HomeSnapshot: Codable {
        var shelves: [String: [Shelf]]
        var playlists: [CardItem]
    }

    private init() {
        if let saved = DiskCache.load([String: CollectionPage].self, from: "collections.json") {
            collections = saved
        }
        if let home = DiskCache.load(HomeSnapshot.self, from: "home.json") {
            shelves = home.shelves
            homePlaylists = home.playlists
        }
    }

    private func persistCollectionsSoon() {
        collectionsTask?.cancel()
        collectionsTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            DiskCache.save(self.collections, as: "collections.json")
        }
    }

    private func persistHomeSoon() {
        homeTask?.cancel()
        homeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            DiskCache.save(HomeSnapshot(shelves: self.shelves, playlists: self.homePlaylists), as: "home.json")
        }
    }

    func clear() {
        collections.removeAll(); artists.removeAll(); shelves.removeAll(); homePlaylists.removeAll()
        DiskCache.remove("collections.json"); DiskCache.remove("library-tracks.json")
        DiskCache.remove("home.json")
    }
}

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - Auth

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isSignedIn = false
    @Published var showLogin = false

    private init() {}

    func bootstrap() async {
        await refresh()
        // Developer convenience: auto-import a baked-in cookie if present and
        // we're not already signed in (kept out of git — see DevCredentials).
        if !isSignedIn, !DevCredentials.cookie.isEmpty {
            _ = await importCookies(DevCredentials.cookie)
        }
    }

    func refresh() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let relevant = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let hasAuth = relevant.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
        InnerTube.shared.cookieHeader = header.isEmpty ? nil : header
        if isSignedIn != hasAuth { isSignedIn = hasAuth }
    }

    func importCookies(_ raw: String) async -> Bool {
        let store = WKWebsiteDataStore.default().httpCookieStore
        var header = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
            guard let cookie = HTTPCookie(properties: [
                .name: String(pair[..<eq]),
                .value: String(pair[pair.index(after: eq)...]),
                .domain: ".youtube.com", .path: "/", .secure: "TRUE",
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
        let targets = records.filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") }
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

// MARK: - Library store

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var playlists: [CardItem] = []
    private var loaded = false
    private var songsCache: [Track]?
    private var songsTask: Task<[Track], Never>?
    private var allTracksCache: [Track]?
    private var allTracksTask: Task<[Track], Never>?
    private var allTracksRefreshed = false

    private init() {}

    func loadIfNeeded() async {
        guard !loaded, AuthManager.shared.isSignedIn else { return }
        // Don't latch `loaded` until a fetch actually succeeds — latching on a
        // transient cold-launch failure left the store EMPTY for the whole
        // session (Home fetches independently and looked fine, while the
        // Add-to-Playlist sheet showed "No playlists"). Every loadIfNeeded
        // call site retries until this succeeds once.
        let fetched = (try? await YTM.shared.libraryPlaylists()) ?? []
        guard !fetched.isEmpty else { return }
        loaded = true
        playlists = fetched
        // Warm liked songs + every playlist page into the cache (disk-backed)
        // in the background, so hearts are correct app-wide and playlists open
        // instantly instead of fetching on first tap.
        Task { _ = await self.allKnownTracks() }
    }

    func songs(forceRefresh: Bool = false) async -> [Track] {
        guard AuthManager.shared.isSignedIn else { return [] }
        if !forceRefresh, let songsCache { return songsCache }
        if !forceRefresh, let songsTask { return await songsTask.value }
        let task = Task<[Track], Never> { (try? await YTM.shared.librarySongs()) ?? [] }
        songsTask = task
        let result = await task.value
        songsCache = result
        songsTask = nil
        PlayerEngine.shared.likedIds.formUnion(result.map(\.videoId))
        return result
    }

    func allKnownTracks() async -> [Track] {
        guard AuthManager.shared.isSignedIn else { return [] }
        if allTracksCache == nil,
           let saved = DiskCache.load([Track].self, from: "library-tracks.json"), !saved.isEmpty {
            allTracksCache = saved
        }
        if let allTracksCache {
            if !allTracksRefreshed {
                allTracksRefreshed = true
                Task {
                    let fresh = await self.fetchAllKnownTracks()
                    if !fresh.isEmpty { self.allTracksCache = fresh; DiskCache.save(fresh, as: "library-tracks.json") }
                }
            }
            return allTracksCache
        }
        if let allTracksTask { return await allTracksTask.value }
        let task = Task<[Track], Never> { await self.fetchAllKnownTracks() }
        allTracksTask = task
        let result = await task.value
        allTracksCache = result
        allTracksTask = nil
        allTracksRefreshed = true
        if !result.isEmpty { DiskCache.save(result, as: "library-tracks.json") }
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
                for id in chunk { group.addTask { (id, try? await YTM.shared.playlist(id: id)) } }
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
        loaded = false; playlists = []
        songsCache = nil; songsTask = nil
        allTracksCache = nil; allTracksTask = nil; allTracksRefreshed = false
        discoverCache = nil
        PageCache.shared.clear()
        Task { await loadIfNeeded() }
    }
}

// MARK: - Navigation

enum LibraryTab: String, CaseIterable, Hashable {
    case playlists = "Playlists"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case podcasts = "Podcasts"

    /// Tabs shown in the UI. Podcasts appears only when the feature is enabled
    /// (see PodcastFeature / PODCASTS.md).
    static var visible: [LibraryTab] {
        var tabs: [LibraryTab] = [.playlists, .songs, .albums, .artists]
        if PodcastFeature.enabled { tabs.append(.podcasts) }
        return tabs
    }

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .songs: return "heart"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .podcasts: return "mic"
        }
    }
}

enum Route: Hashable {
    case album(String)
    case playlist(String)
    case artist(String)
    case podcastShow(String)
    case browse(String)
    case search(String, YTM.SearchFilter?)
    case mostPlayed
}

@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    @Published var selectedTab = 0
    @Published var homePath = NavigationPath()
    @Published var searchPath = NavigationPath()
    @Published var libraryPath = NavigationPath()

    func go(_ route: Route) {
        switch selectedTab {
        case 0: homePath.append(route)
        case 1: searchPath.append(route)
        default: libraryPath.append(route)
        }
    }

    func goArtist(id: String?, name: String) {
        if let id {
            if id.hasPrefix("MPLA") { go(.artist(String(id.dropFirst(4)))); return }
            if id.hasPrefix("UC") { go(.artist(id)); return }
            if id.hasPrefix("FE") { go(.browse(id)); return }
        }
        let q = name.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { go(.search(q, .artists)) }
    }

    func open(_ item: CardItem) {
        switch item.kind {
        case .album: if let id = item.browseId { go(.album(id)) }
        case .podcast: if PodcastFeature.enabled, let id = item.browseId { go(.podcastShow(id)) }
        case .artist: goArtist(id: item.browseId, name: item.title)
        case .playlist:
            // Open the playlist page (a list). Browsable playlists — including
            // "RD"-prefixed auto-playlists like "New Episodes" — should list, not
            // auto-play. True radios arrive as `.station` and play instantly.
            if let id = item.playlistId { go(.playlist(id)) }
        case .station:
            if let id = item.playlistId { PlayerEngine.shared.playStation(playlistId: id, title: item.title) }
        case .song, .video:
            if let videoId = item.videoId {
                PlayerEngine.shared.playRadio(from: Track(videoId: videoId, title: item.title,
                                                          artistLine: item.subtitle, thumbnailURL: item.thumbnailURL,
                                                          isVideo: item.kind == .video))
            }
        case .unknown: break
        }
    }
}

// MARK: - Login web view

struct LoginWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: AuthManager.loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.host?.contains("music.youtube.com") == true else { return }
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

struct LoginSheet: View {
    @EnvironmentObject var auth: AuthManager
    @State private var pasteMode = false
    @State private var cookieText = ""
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if pasteMode { pasteView } else { LoginWebView() }
            }
            .navigationTitle(pasteMode ? "Import Session" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { Task { await auth.refresh(); auth.showLogin = false } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(pasteMode ? "Use Login" : "Paste Cookies") { pasteMode.toggle() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var pasteView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("On a computer at music.youtube.com, copy the request `cookie:` header (DevTools → Network) and paste it here.")
                .font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $cookieText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
            Button {
                Task {
                    if await auth.importCookies(cookieText) { auth.showLogin = false }
                    else { importError = "No valid session found — make sure SAPISID is included." }
                }
            } label: {
                Text("Import").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
        .padding()
    }
}
