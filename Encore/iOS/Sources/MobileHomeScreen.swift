import SwiftUI
import EncoreCore

// MARK: - Home

/// Home is a deliberately minimal launcher (Charlie's spec, 2026-08-14):
/// his playlists, then his saved albums, and nothing else.
///
/// It replaced BOTH of the old first two tabs — the old Home (which was the
/// Favorite Songs playlist, `FavoritesScreen`) and the old Explore shelf
/// feed that used to live in this type (YouTube's home shelves, R&B,
/// Classics, Discover, podcast episodes, drag-to-reorder shortcuts). The
/// Explore tab is gone; R&B is still one tap away as a playlist here.
/// Section ordering lives in `EncoreCore.HomeSections` so macOS matches.
/// Last time Home actually refetched. Lives outside the view because the tab
/// recreates HomeScreen on every selection, so view state can't remember it.
@MainActor private enum HomeRefreshClock {
    static var last: Date?
}

struct HomeScreen: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var nav: Nav
    @State private var playlists: [CardItem] = []
    @State private var albums: [CardItem] = []
    @State private var loading = true
    /// Bumped when native artist names finish resolving, purely to re-render.
    @State private var nameVersion = 0

    private let rowHeight: CGFloat = 76

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                let _ = nameVersion   // re-render when native names land
                if !playlists.isEmpty {
                    section("Playlists", items: HomeSections.orderedPlaylists(playlists))
                }
                if !albums.isEmpty {
                    section("Albums", items: albums)
                }
                if loading, playlists.isEmpty, albums.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Home")
        .toolbar { accountButton }
        .refreshable { await load(force: true) }
        .task(id: auth.isSignedIn) { await load() }
    }

    @ViewBuilder private func section(_ title: String, items: [CardItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
            VStack(spacing: 8) {
                ForEach(items) { item in
                    Button { nav.open(item) } label: { row(item) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// One full-width entry (artwork + title, plus the artist line for albums).
    @ViewBuilder private func row(_ item: CardItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.thumbnailURL, corner: 6).frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    // "Album • Jacky Cheung • 2004" → "Album • 张学友 • 2004"
                    Text(NativeNames.rewriting(item.subtitle, artists: item.subtitle.subtitleParts))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }



    /// Refetched at most once every `refreshInterval`, or on demand via
    /// pull-to-refresh. `.task(id:)` re-fires every time the Home TAB is
    /// selected, and refetching there meant two network round-trips and a
    /// full list reassignment on every visit — the rows rebuilt and the
    /// artwork visibly reloaded (Charlie, 2026-08-18). Your own library
    /// barely changes minute to minute, so this is nothing but churn.
    private static let refreshInterval: TimeInterval = 300

    private func load(force: Bool = false) async {
        // Seed instantly from the disk-backed cache (persists across launches)
        // so Home isn't a spinner on every cold start, then refresh below.
        if playlists.isEmpty, !PageCache.shared.homePlaylists.isEmpty {
            playlists = PageCache.shared.homePlaylists
        }
        if albums.isEmpty, !PageCache.shared.homeAlbums.isEmpty {
            albums = PageCache.shared.homeAlbums
        }
        guard auth.isSignedIn else { loading = false; return }

        let haveContent = !playlists.isEmpty || !albums.isEmpty
        if !force, haveContent, let last = HomeRefreshClock.last,
           Date().timeIntervalSince(last) < Self.refreshInterval {
            loading = false
            return
        }
        loading = !haveContent

        async let playlistTask = (try? await YTM.shared.libraryPlaylists()) ?? []
        async let albumTask = (try? await YTM.shared.libraryAlbums()) ?? []
        let (freshPlaylists, freshAlbums) = await (playlistTask, albumTask)
        HomeRefreshClock.last = Date()
        // Only reassign when something actually CHANGED: an identical array of
        // fresh CardItem values still invalidates every row.
        if !freshPlaylists.isEmpty {
            if freshPlaylists.map(\.id) != playlists.map(\.id) { playlists = freshPlaylists }
            PageCache.shared.homePlaylists = freshPlaylists
        }
        if !freshAlbums.isEmpty {
            if freshAlbums.map(\.id) != albums.map(\.id) { albums = freshAlbums }
            PageCache.shared.homeAlbums = freshAlbums
        }
        loading = false

        // Resolve native names for the artists credited on these albums, then
        // re-render. Results persist, so this is one-time per artist.
        let candidates = albums.flatMap { $0.subtitle.subtitleParts }
        if await NativeNames.warmUp(names: candidates) {
            nameVersion &+= 1
            PlayerEngine.shared.nameVersion &+= 1
        }
    }
}
