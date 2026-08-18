import SwiftUI
import EncoreCore

// MARK: - Sorting / filtering (parity with macOS)

enum SortMode: String, CaseIterable {
    case recent = "Recently Added"
    /// Playlist pages only: newest-first by playlist position (reverse order).
    /// Labelled "Recently Added"; `recent` is relabelled "Playlist Order" there.
    case added = "Added"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    /// YouTube's global play count (artist Top songs).
    case plays = "Plays"
    /// YOUR play counts (PlayCounts) — never-played songs sort first under
    /// Least Played, which is how you find what you've been skipping.
    case mostPlayed = "Most Played"
    case leastPlayed = "Least Played"
}

enum TrackSort {
    /// Filter (CJK-aware) then sort tracks. `keepOrder` forces source order.
    /// Delegates to the shared, unit-tested `LibrarySort` so iOS/macOS match.
    static func apply(_ tracks: [Track], filter: String, sort: SortMode, keepOrder: Bool) -> [Track] {
        let filtered = LibrarySort.filter(tracks, query: filter)
        if keepOrder { return filtered }
        return LibrarySort.sort(filtered, by: sort.trackOrder)
    }

    static func cards(_ cards: [CardItem], filter: String, sort: SortMode) -> [CardItem] {
        LibrarySort.arrangeCards(cards, query: filter, order: sort.cardOrder)
    }
}

private extension SortMode {
    var trackOrder: TrackOrder {
        switch self {
        case .recent: return .source
        case .added: return .reversed
        case .title: return .title
        case .artist: return .artist
        case .album: return .album
        case .plays: return .plays
        case .mostPlayed: return .mostPlayed
        case .leastPlayed: return .leastPlayed
        }
    }
    /// Cards only carry title + subtitle, so artist/album both key off subtitle.
    var cardOrder: CardOrder {
        switch self {
        case .recent: return .source
        case .added: return .reversed
        case .title: return .title
        case .artist, .album: return .subtitle
        case .plays, .mostPlayed, .leastPlayed: return .source
        }
    }
}

/// Filter field + sort menu, matching the macOS controls.
struct SortFilterBar: View {
    @Binding var filter: String
    @Binding var sort: SortMode
    var sortOptions: [SortMode]
    var sortLabel: (SortMode) -> String = { $0.rawValue }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Filter", text: $filter).font(.system(size: 13)).autocorrectionDisabled()
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.card, in: Capsule())
            if sortOptions.count > 1 {
                Menu {
                    ForEach(sortOptions, id: \.self) { opt in
                        Button { sort = opt } label: {
                            if sort == opt { Label(sortLabel(opt), systemImage: "checkmark") } else { Text(sortLabel(opt)) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                        Text(sortLabel(sort)).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    // Without an explicit hit shape the label is only
                    // hittable on the glyphs themselves, and the tap fell
                    // through to the card grid below — tapping "Recently
                    // Added" in Library ▸ Artists opened Jay Chou, the card
                    // nearest behind it (Charlie, 2026-08-18).
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        // Hit-test above the content below it: siblings later in the stack
        // win ties, so the grid could claim touches meant for this bar.
        .zIndex(1)
    }
}

// MARK: - Shared rows / cards

struct TrackRowView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    let track: Track
    /// Album pages: rows share the album art, so show the track number instead.
    var index: Int? = nil
    var showsArtwork = true
    /// Shown when the track itself carries no artist credit. YouTube omits the
    /// per-track artist on plenty of album pages (it's implied by the album),
    /// which left those rows reading " · 70K plays" — a dangling separator and
    /// no singer — while albums that DO carry it read "张学友 · 76K plays".
    /// Album pages pass their header artist so every row reads the same way.
    var fallbackArtist: String? = nil
    var onRemoveFromPlaylist: (() -> Void)?
    /// Bumped by the parent when native artist names finish resolving. The
    /// row's own data doesn't change, so without a property that DOES change
    /// SwiftUI reuses the rendered row and the name stays romanized until you
    /// navigate away and back.
    var nameVersion = 0
    /// Multi-select mode: the row shows a checkbox and a tap toggles it
    /// instead of playing. The parent owns the selection itself.
    var isSelecting = false
    var isSelected = false
    let onPlay: () -> Void
    @State private var played = false
    @State private var swipeOffset: CGFloat = 0
    @State private var showAddToPlaylist = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Swipe reveals (custom drag — .swipeActions only works inside
            // List, and these rows live in LazyVStacks): right = Play Next,
            // left = Remove from Playlist (playlist pages only).
            if swipeOffset > 0 {
                HStack(spacing: 7) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 15, weight: .semibold))
                    if swipeOffset > 60 {
                        Text("Play Next").font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            } else if swipeOffset < 0 {
                HStack(spacing: 7) {
                    if swipeOffset < -60 {
                        Text("Remove").font(.system(size: 13, weight: .semibold))
                    }
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            }
            rowContent.offset(x: swipeOffset)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        // YouTube already told us it won't play this one (grey row). Dim it and
        // swallow the tap: playing it only ever yields error 150 and a skip.
        .opacity(track.isUnavailable ? 0.4 : 1)
        .onTapGesture { if isSelecting || !track.isUnavailable { onPlay() } }
        .gesture(playNextSwipe, isEnabled: !isSelecting)
        .onAppear { if PodcastFeature.enabled, track.isEpisode { played = PlayedEpisodes.isPlayed(track.videoId) } }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(track: track).environmentObject(player)
        }
    }

    /// Horizontal-intent drag: right past the threshold queues the track to
    /// play next; left removes it from the playlist (only on rows that can).
    /// Vertical scrolling stays untouched.
    private var playNextSwipe: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                let lower: CGFloat = onRemoveFromPlaylist != nil ? -96 : 0
                swipeOffset = max(lower, min(v.translation.width, 96))
            }
            .onEnded { _ in
                let playNextTriggered = swipeOffset > 60
                let removeTriggered = swipeOffset < -60
                withAnimation(.spring(duration: 0.3)) { swipeOffset = 0 }
                if playNextTriggered {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    player.playNext(track)
                } else if removeTriggered {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onRemoveFromPlaylist?()
                }
            }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .frame(width: 24)
            }
            if showsArtwork {
                ArtworkView(url: track.thumbnailURL, corner: 5).frame(width: 52, height: 52)
            } else if let index {
                Text("\(index + 1)")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(player.current?.videoId == track.videoId
                                     ? Theme.accent : Theme.textSecondary)
                    .frame(width: 28, height: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(NativeNames.displayTitle(for: track))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(player.current?.videoId == track.videoId ? Theme.accent
                                     : (played ? Theme.textTertiary : Theme.textPrimary))
                    .lineLimit(1)
                // CJK artists show their native name (张学友, not "Jacky
                // Cheung") once it's resolved; everyone else is unchanged.
                let credited = track.artistLine.isEmpty ? (fallbackArtist ?? "") : track.artistLine
                let artistLine = NativeNames.rewriting(credited,
                                                       artists: track.artists.map(\.name) + [credited])
                // Joined from the non-empty parts only: either half can be
                // missing, and a hardcoded " · " left a dangling separator.
                Text([artistLine, track.playsText ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            if PodcastFeature.enabled, track.isEpisode {
                Button {
                    PlayedEpisodes.toggle(track.videoId)
                    played = PlayedEpisodes.isPlayed(track.videoId)
                } label: {
                    Image(systemName: played ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(played ? Theme.accent : Theme.textSecondary)
                        .frame(width: 34, height: 52)
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button("Play") { onPlay() }
                Button("Play Next") { player.playNext(track) }
                Button("Add to Queue") { player.addToQueue(track) }
                Button("Start Radio") { player.playRadio(from: track) }
                if PodcastFeature.enabled, track.isEpisode {
                    Button(played ? "Mark as Unplayed" : "Mark as Played") {
                        PlayedEpisodes.toggle(track.videoId)
                        played = PlayedEpisodes.isPlayed(track.videoId)
                    }
                }
                if let a = track.artists.first {
                    Button("Go to Artist") { nav.goArtist(id: a.id, name: a.name) }
                }
                Button(player.likedIds.contains(track.videoId) ? "Remove from Liked" : "Add to Liked") {
                    player.toggleLike(track)
                }
                Button("Add to Playlist") { showAddToPlaylist = true }
                if let url = track.shareURL {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button {
                        UIPasteboard.general.url = url
                    } label: { Label("Copy Link", systemImage: "link") }
                }
                if let onRemoveFromPlaylist {
                    Button("Remove from Playlist", role: .destructive) { onRemoveFromPlaylist() }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 52)
            }
        }
    }
}

struct CardCircleOrSquare: View {
    @EnvironmentObject var nav: Nav
    let item: CardItem

    var body: some View {
        Button { nav.open(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(url: Artwork.upscale(item.thumbnailURL, to: 300),
                            corner: item.kind == .artist ? 80 : 8)
                    .aspectRatio(1, contentMode: .fit)
                Text(item.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    .multilineTextAlignment(item.kind == .artist ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: item.kind == .artist ? .center : .leading)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct ShelfRow: View {
    /// Rows shown for a vertical song shelf before it's truncated (YouTube
    /// returns 50). Charlie's call — enough to actually browse, still short of
    /// the 50-row walls that buried everything below them.
    static let verticalTrackLimit = 30

    let shelf: Shelf
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav

    /// Playlist behind the shelf's "more" link (e.g. an artist's full Top songs,
    /// ranked by plays). Only for track shelves that link to a playlist.
    private var allSongsPlaylistId: String? {
        guard shelf.isTrackShelf, let id = shelf.moreBrowseId, id.hasPrefix("VL") else { return nil }
        return String(id.dropFirst(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !shelf.title.isEmpty {
                HStack {
                    Text(shelf.title).font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let plId = allSongsPlaylistId {
                        Button { nav.go(.playlist(plId)) } label: {
                            HStack(spacing: 2) {
                                Text("Show all").font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            }.foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            if shelf.isTrackShelf {
                // Song shelves read as a vertical list, same as macOS: a row per
                // track, and tapping one plays the shelf from there rather than
                // starting a radio off it. Unlike macOS these are capped —
                // YouTube returns 50 per shelf, and several stacked 50-row walls
                // bury everything below them on a phone. Tapping still queues the
                // WHOLE shelf, and the weekly rotation brings the rest around.
                let tracks = shelf.tracks
                LazyVStack(spacing: 0) {
                    ForEach(Array(shelf.items.prefix(Self.verticalTrackLimit).enumerated()), id: \.offset) { _, item in
                        switch item {
                        case .track(let track):
                            TrackRowView(track: track, onRemoveFromPlaylist: nil) {
                                let start = tracks.firstIndex(of: track) ?? 0
                                player.playCollection(tracks, startAt: start)
                            }
                        case .card(let card):
                            CardCircleOrSquare(item: card).frame(width: 118)
                        }
                    }
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                            if case .card(let card) = item {
                                CardCircleOrSquare(item: card).frame(width: 118)
                            } else if case .track(let track) = item {
                                Button {
                                    if track.isEpisode {
                                        // Episodes: play directly with the shelf as
                                        // the queue — an RDAMVM "episode radio" is
                                        // junk that errors through items (songs
                                        // keep YT's tap-starts-radio behavior).
                                        let episodes = shelf.items.compactMap { item -> Track? in
                                            if case .track(let t) = item, t.isEpisode { return t }
                                            return nil
                                        }
                                        let start = episodes.firstIndex { $0.videoId == track.videoId } ?? 0
                                        player.playCollection(episodes, startAt: start)
                                    } else {
                                        player.playRadio(from: track)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ArtworkView(url: Artwork.upscale(track.thumbnailURL, to: 300), corner: 8)
                                            .frame(width: 118, height: 118)
                                        Text(NativeNames.displayTitle(track.title)).font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary).lineLimit(1).frame(width: 118, alignment: .leading)
                                        Text(track.playsText ?? track.artistLine).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                            .lineLimit(1).frame(width: 118, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

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
                    Text(NativeNames.rewriting(item.subtitle, artists: subtitleNameCandidates(item.subtitle)))
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

    /// Card subtitles are pre-joined ("Album • Jacky Cheung • 2004"), and the
    /// card carries no separate artist field — so treat each separator-
    /// delimited part as a possible artist name and let the cache decide.
    private func subtitleNameCandidates(_ subtitle: String) -> [String] {
        subtitle.components(separatedBy: CharacterSet(charactersIn: "•·"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
        let candidates = albums.flatMap { subtitleNameCandidates($0.subtitle) }
        if await NativeNames.warmUp(names: candidates) {
            nameVersion &+= 1
            PlayerEngine.shared.nameVersion &+= 1
        }
    }
}

var accountButton: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) { AccountButton() }
}

struct AccountButton: View {
    @EnvironmentObject var auth: AuthManager
    var body: some View {
        Menu {
            if auth.isSignedIn {
                Text("Signed in")
                Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
            } else {
                Button("Sign in with Google") { auth.showLogin = true }
            }
        } label: {
            Image(systemName: auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
        }
    }
}

// MARK: - Search

struct SearchScreen: View {
    var initialQuery: String = ""
    var initialFilter: YTM.SearchFilter? = nil

    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    @State private var query = ""
    @State private var filter: YTM.SearchFilter?
    @State private var results = SearchResults()
    @State private var loading = false
    @State private var started = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", filter == nil) { filter = nil; Task { await run() } }
                        ForEach(YTM.SearchFilter.allCases, id: \.self) { f in
                            chip(f.title, filter == f) { filter = f; Task { await run() } }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                ForEach(results.shelves) { shelf in
                    if shelf.isTrackShelf {
                        VStack(spacing: 0) {
                            ForEach(Array(shelf.tracks.enumerated()), id: \.offset) { i, t in
                                TrackRowView(track: t, onRemoveFromPlaylist: nil) {
                                    player.playCollection(shelf.tracks, startAt: i)
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    } else {
                        ShelfRow(shelf: shelf)
                    }
                }
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, albums, artists…")
        .onSubmit(of: .search) { Task { await run() } }
        .task {
            guard !started else { return }
            started = true
            if !initialQuery.isEmpty { query = initialQuery; filter = initialFilter; await run() }
        }
    }

    private func chip(_ title: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? .black : Theme.textPrimary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.white : Theme.card))
        }
        .buttonStyle(.plain)
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        results = (try? await YTM.shared.search(q, filter: filter)) ?? SearchResults()
        loading = false
    }
}

// MARK: - Library

struct LibraryScreen: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var library: LibraryStore
    @State private var tab: LibraryTab = .playlists
    @State private var cards: [CardItem] = []
    @State private var tracks: [Track] = []
    @State private var loading = false
    @State private var filter = ""
    @State private var songSort: SortMode = .recent
    @State private var cardSort: SortMode = .recent

    private let cols = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    private var visibleTracks: [Track] {
        TrackSort.apply(tracks, filter: filter, sort: songSort, keepOrder: false)
    }
    private var visibleCards: [CardItem] {
        TrackSort.cards(cards, filter: filter, sort: cardSort)
    }
    private var sortOptions: [SortMode] {
        // Full options in every Library tab.
        var opts: [SortMode] = [.recent, .title, .artist, .album]
        if PlayCountsFeature.enabled { opts += [.mostPlayed, .leastPlayed] }
        return opts
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $tab) {
                    ForEach(LibraryTab.visible, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if auth.isSignedIn && !loading && tab != .mostPlayed {
                    SortFilterBar(filter: $filter,
                                  sort: tab == .songs ? $songSort : $cardSort,
                                  sortOptions: sortOptions,
                                  sortLabel: { tab == .artists && $0 == .title ? "Name" : $0.rawValue })
                }

                if !auth.isSignedIn {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.circle").font(.system(size: 40)).foregroundStyle(Theme.textTertiary)
                        Text("Sign in to see your library").foregroundStyle(Theme.textSecondary)
                        Button("Sign in with Google") { auth.showLogin = true }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if tab == .mostPlayed {
                    MostPlayedList()
                } else if tab == .songs {
                    let shown = visibleTracks
                    if shown.count > 1 {
                        HStack(spacing: 10) {
                            Button { player.playCollection(shown, startAt: 0) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            Button { player.playShuffled(shown) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                        }.padding(.horizontal, 16)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                            TrackRowView(track: t, onRemoveFromPlaylist: nil) { player.playCollection(shown, startAt: i) }
                                .padding(.horizontal, 16)
                        }
                    }
                } else {
                    LazyVGrid(columns: cols, spacing: 16) {
                        ForEach(visibleCards) { CardCircleOrSquare(item: $0) }
                    }
                    .padding(.horizontal, 16)
                }
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Library")
        .toolbar { accountButton }
        .refreshable { await load(force: true) }
        .task(id: "\(auth.isSignedIn)-\(tab.rawValue)") { restoreSort(); await load() }
        // The Songs list is handed a snapshot of the track cache, so when the
        // background refresh lands it has to be told to pick the new one up.
        .onChange(of: library.allTracksVersion) { _, _ in
            guard tab == .songs else { return }
            Task { tracks = await LibraryStore.shared.allKnownTracks() }
        }
        .onChange(of: songSort) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "sort-lib-songs") }
        .onChange(of: cardSort) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "sort-lib-\(tab.rawValue)") }
    }

    private func restoreSort() {
        if let s = UserDefaults.standard.string(forKey: "sort-lib-songs").flatMap(SortMode.init) { songSort = s }
        if let s = UserDefaults.standard.string(forKey: "sort-lib-\(tab.rawValue)").flatMap(SortMode.init) { cardSort = s }
        else { cardSort = .recent }
    }

    private func load(force: Bool = false) async {
        guard auth.isSignedIn else { return }
        loading = true
        switch tab {
        case .playlists: cards = (try? await YTM.shared.libraryPlaylists()) ?? []
        case .songs: tracks = await LibraryStore.shared.allKnownTracks(forceRefresh: force)
        case .albums: cards = (try? await YTM.shared.libraryAlbums()) ?? []
        case .artists:
            let corpus = (try? await YTM.shared.libraryArtists()) ?? []
            let all = await LibraryStore.shared.allKnownTracks()
            cards = Self.artistCards(corpus: corpus, tracks: all)
        case .podcasts:
            cards = (try? await YTM.shared.libraryPodcasts()) ?? []
        case .mostPlayed:
            break   // PlayCounts is local; MostPlayedList loads it itself.
        }
        loading = false
    }

    /// Aggregate artists across likes + all playlists (parity with macOS).
    static func artistCards(corpus: [CardItem], tracks: [Track]) -> [CardItem] {
        struct Tally { var name: String; var count = 0; var thumb: URL? }
        var byId: [String: Tally] = [:]
        var byName: [String: Tally] = [:]
        for track in tracks {
            for ref in track.artists {
                if let id = ref.id, id.hasPrefix("UC") {
                    var t = byId[id] ?? Tally(name: ref.name); t.count += 1
                    if t.thumb == nil { t.thumb = track.thumbnailURL }; byId[id] = t
                } else if !ref.name.isEmpty {
                    let k = ref.name.matchNormalized
                    var t = byName[k] ?? Tally(name: ref.name); t.count += 1
                    if t.thumb == nil { t.thumb = track.thumbnailURL }; byName[k] = t
                }
            }
            if track.artists.isEmpty {
                let name = track.artistLine.components(separatedBy: CharacterSet(charactersIn: ",&"))
                    .first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !name.isEmpty else { continue }
                let k = name.matchNormalized
                var t = byName[k] ?? Tally(name: name); t.count += 1
                if t.thumb == nil { t.thumb = track.thumbnailURL }; byName[k] = t
            }
        }
        func label(_ n: Int) -> String { "\(n) song\(n == 1 ? "" : "s")" }
        var out: [CardItem] = []
        var seenIds = Set<String>(); var seenNames = Set<String>()
        for card in corpus {
            let cid = card.browseId.map { $0.hasPrefix("MPLA") ? String($0.dropFirst(4)) : $0 }
            var item = card
            if let cid, let t = byId[cid] { item.subtitle = label(t.count) }
            out.append(item)
            if let cid { seenIds.insert(cid) }
            seenNames.insert(card.title.matchNormalized)
        }
        func isDup(_ name: String) -> Bool {
            let n = name.matchNormalized
            guard n.count >= 3 else { return seenNames.contains(n) }
            return seenNames.contains { $0.contains(n) || n.contains($0) }
        }
        for (id, t) in byId.sorted(by: { $0.value.count > $1.value.count }) where !seenIds.contains(id) && !isDup(t.name) {
            seenNames.insert(t.name.matchNormalized)
            out.append(CardItem(kind: .artist, title: t.name, subtitle: label(t.count), thumbnailURL: t.thumb, browseId: id))
        }
        for (k, t) in byName where !isDup(t.name) {
            seenNames.insert(k)
            out.append(CardItem(kind: .artist, title: t.name, subtitle: label(t.count), thumbnailURL: t.thumb))
        }
        func cnt(_ i: CardItem) -> Int { Int(i.subtitle.components(separatedBy: " ").first ?? "") ?? 0 }
        return out.sorted { cnt($0) != cnt($1) ? cnt($0) > cnt($1) : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

// MARK: - Collection (album/playlist)

struct CollectionScreen: View {
    enum Kind: Hashable { case album(String), playlist(String), podcast(String) }
    let kind: Kind

    @EnvironmentObject var player: PlayerEngine
    @State private var page: CollectionPage?
    @State private var loading = true
    @State private var filter = ""
    @State private var sort: SortMode = .recent
    @State private var showEdit = false
    @State private var appliedDefaultSort = false
    @State private var savingToLibrary = false
    /// Multi-select: pick songs to remove from this playlist, or to add to
    /// another one. Holds videoIds.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var showAddSelection = false
    @State private var workingOnSelection = false
    /// Bumped when native artist names finish resolving, purely to re-render.
    @State private var nameVersion = 0

    private var cacheKey: String {
        switch kind {
        case .album(let id): return "album-\(id)"
        case .playlist(let id): return "playlist-\(id)"
        case .podcast(let id): return "podcast-\(id)"
        }
    }
    private var playlistId: String? { if case .playlist(let id) = kind { return id }; return nil }
    private var sortStorageKey: String { "sort-\(cacheKey)" }
    private var isAlbum: Bool { if case .album = kind { return true }; return false }
    private var isPlaylist: Bool { if case .playlist = kind { return true }; return false }

    /// Artist names credited on this page, for rewriting the header subtitle
    /// and rows to native names. The subtitle arrives pre-joined, so the
    /// names have to come from the tracks.
    ///
    /// Follows the DISPLAYED order (sorted/filtered), not `page.tracks` —
    /// playlists open sorted by artist, so the raw order resolved artists
    /// that were nowhere near the top of the screen while the visible ones
    /// stayed romanized. Deduped in first-seen order for the same reason:
    /// what's on screen resolves first, then the rest of the list.
    ///
    /// EVERY track is walked, not a prefix — a 692-track playlist has far
    /// more artists than one screenful, and capping this left the songs
    /// further down permanently romanized.
    private func artistNames(in page: CollectionPage) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        // The header's own artist FIRST. Plenty of album pages carry no
        // per-track artist at all, and harvesting only from tracks left those
        // headers stuck on the romanized name ("David Tao • Album • 2014")
        // while albums whose tracks do carry it resolved to 张学友.
        if let headerArtist = headerArtist(of: page), seen.insert(headerArtist).inserted {
            names.append(headerArtist)
        }
        for track in shownTracks(page) {
            for name in track.artists.map(\.name) + [track.artistLine]
            where !name.isEmpty && seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// The artist an album page is billed to. Album subtitles arrive
    /// pre-joined and artist-first ("David Tao • Album • 2014"), so the
    /// leading component is the name. nil for playlists, which are billed to
    /// their owner rather than an artist.
    private func headerArtist(of page: CollectionPage) -> String? {
        guard isAlbum else { return nil }
        let first = page.subtitle
            .components(separatedBy: CharacterSet(charactersIn: "•·"))
            .first?
            .trimmingCharacters(in: .whitespaces)
        guard let first, !first.isEmpty else { return nil }
        return first
    }
    /// Save/remove this album in the library. Flips the local state first so the
    /// button responds immediately, and rolls back if YouTube rejects it.
    private func setSaved(_ saved: Bool, target: String) {
        guard !savingToLibrary else { return }
        savingToLibrary = true
        page?.savedToLibrary = saved
        Task {
            defer { savingToLibrary = false }
            do {
                try await YTM.shared.setAlbumSaved(playlistId: target, saved: saved)
                player.showToast(saved ? "Saved to library" : "Removed from library")
            } catch {
                page?.savedToLibrary = !saved
                player.showToast("Couldn't update your library")
            }
        }
    }

    /// Unavailable tracks are HIDDEN, not dimmed (Charlie, 2026-08-16).
    /// `isUnavailable` is re-read from YouTube on every load, so this
    /// self-heals: when a track stops being greyed out the next fetch
    /// reports it available and it comes straight back — no bookkeeping and
    /// no extra polling needed.
    private func shownTracks(_ page: CollectionPage) -> [Track] {
        let available = page.tracks.filter { !$0.isUnavailable }
        return TrackSort.apply(available, filter: filter, sort: sort, keepOrder: sort == .recent)
    }

    /// How many the filter above is holding back, so they aren't a silent
    /// disappearance.
    private func hiddenCount(_ page: CollectionPage) -> Int {
        page.tracks.filter(\.isUnavailable).count
    }
    /// "Plays" only for play-count-ranked lists (e.g. an artist's Top songs).
    private var sortOptions: [SortMode] {
        if isAlbum { return [] }
        var opts: [SortMode] = [.recent, .added, .title, .artist, .album]
        if let page, LibrarySort.hasPlayCounts(page.tracks) { opts.append(.plays) }
        if PlayCountsFeature.enabled { opts += [.mostPlayed, .leastPlayed] }
        return opts
    }
    /// Default a play-count-ranked playlist to the Plays sort, once.
    private func applyDefaultSort(_ tracks: [Track]) {
        guard isPlaylist, !appliedDefaultSort, !tracks.isEmpty else { return }
        appliedDefaultSort = true
        if LibrarySort.hasPlayCounts(tracks) { sort = .plays }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let _ = nameVersion   // re-render when native names land
                if let page {
                    // No cover art inside a collection page at all — playlists
                    // or albums (Charlie's call, 2026-08-14): it just pushes
                    // the tracks down. Art still shows everywhere you PICK a
                    // collection (Home, Library, search) and on the row/now-
                    // playing surfaces.
                    // The title is already in the nav bar — repeating it here
                    // just cost a screenful (Charlie, 2026-08-14). Albums keep
                    // their subtitle line; playlists show nothing at all, so
                    // the tracks start at the top.
                    if !page.subtitle.isEmpty, !isPlaylist {
                        // "Jacky Cheung · Album · 2004" → "张学友 · Album · 2004"
                        Text(NativeNames.rewriting(page.subtitle, artists: artistNames(in: page)))
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.top, 8)
                    }
                    let shown = shownTracks(page)
                    SortFilterBar(filter: $filter, sort: $sort,
                                  sortOptions: sortOptions,
                                  sortLabel: {
                                      switch $0 {
                                      case .recent: return "Playlist Order"
                                      case .added: return "Recently Added"
                                      default: return $0.rawValue
                                      }
                                  })
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                            TrackRowView(track: t,
                                         index: i,
                                         showsArtwork: !isAlbum,
                                         fallbackArtist: headerArtist(of: page),
                                         onRemoveFromPlaylist: isPlaylist ? { remove(t) } : nil,
                                         nameVersion: nameVersion,
                                         isSelecting: selecting,
                                         isSelected: selection.contains(t.videoId)) {
                                if selecting {
                                    toggle(t)
                                } else {
                                    player.playCollection(shown, startAt: i, playlistId: playlistId)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    if hiddenCount(page) > 0 {
                        Text("\(hiddenCount(page)) unavailable on YouTube Music — hidden")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
        }
        .background(Theme.bg)
        // Play/Shuffle live pinned at the BOTTOM (Charlie, 2026-08-14): at
        // the top of a 100-track list they were a stretch for the thumb, and
        // scrolled away entirely. Sits above the mini player when one shows.
        //
        // safeAreaInset, NOT overlay (Charlie, 2026-08-18, "the play shuffle
        // button kind of blocks"): an overlay floats ON TOP of the rows, so
        // the bar sat over two tracks at every scroll position and a
        // fixed-height spacer at the end of the list only rescued the last
        // few. As an inset it occupies real layout space — the list is
        // inset by exactly the bar's height, so no row is ever covered.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                selectionBar
            } else if let page {
                let shown = shownTracks(page)
                HStack(spacing: 10) {
                    Button { player.playCollection(shown, startAt: 0, playlistId: playlistId) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button { player.playShuffled(shown, playlistId: playlistId) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    // Albums carry a library toggle; playlists don't.
                    if let saved = page.savedToLibrary, let target = page.libraryTargetPlaylistId {
                        Button { setSaved(!saved, target: target) } label: {
                            Image(systemName: saved ? "checkmark" : "plus").frame(minWidth: 28)
                        }
                        .buttonStyle(.bordered)
                        .disabled(savingToLibrary)
                        .accessibilityLabel(saved ? "Remove album from library" : "Save album to library")
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12)
                // Clears the mini player, which floats over everything from
                // MobileRoot (52pt artwork + 18pt padding + 3pt progress).
                .padding(.bottom, player.current != nil ? 81 : 8)
            }
        }
        .navigationTitle(page?.title ?? "").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if page != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button("Done") { endSelection() }
                    } else {
                        // The pencil covers both kinds of editing: picking
                        // songs in bulk (any collection) and the playlist's
                        // own details (your own playlists).
                        Menu {
                            Button {
                                selecting = true
                                selection = []
                            } label: { Label("Select Songs", systemImage: "checkmark.circle") }
                            if isPlaylist {
                                Button { showEdit = true } label: {
                                    Label("Edit Details…", systemImage: "pencil")
                                }
                            }
                        } label: { Image(systemName: "pencil") }
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let id = playlistId, let page {
                PlaylistEditSheet(playlistId: id, title: page.title, description: page.description ?? "",
                                  onSaved: { newTitle, newDesc in
                    if var updated = self.page {
                        updated.title = newTitle; updated.description = newDesc
                        self.page = updated; PageCache.shared.collections[cacheKey] = updated
                    }
                }, onDeleted: {
                    Nav.shared.pop()   // the page no longer exists
                })
            }
        }
        .sheet(isPresented: $showAddSelection) {
            AddToPlaylistSheet(tracks: selectedTracks) { endSelection() }
                .environmentObject(player)
        }
        .refreshable { await load() }
        .task {
            // Playlists always open sorted by artist.
            if isPlaylist {
                sort = .artist
            } else if let saved = UserDefaults.standard.string(forKey: sortStorageKey).flatMap(SortMode.init) {
                sort = saved
            }
            await load()
        }
        .onChange(of: sort) { _, newSort in
            // Don't persist for playlists — they should reopen sorted by artist.
            if !isPlaylist { UserDefaults.standard.set(newSort.rawValue, forKey: sortStorageKey) }
        }
    }

    /// Actions for the picked songs. Mirrors the Play/Shuffle bar's position
    /// so the buttons stay under the thumb.
    private var selectionBar: some View {
        VStack(spacing: 8) {
            Text(selection.isEmpty ? "Select songs" : "\(selection.count) selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Button { showAddSelection = true } label: {
                    Label("Add", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(selection.isEmpty || workingOnSelection)

                // Removing is only meaningful on a playlist you own; YouTube
                // rejects it elsewhere (the toast says so if it does).
                if isPlaylist {
                    Button(role: .destructive) { removeSelected() } label: {
                        Label("Remove", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selection.isEmpty || workingOnSelection)
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, player.current != nil ? 118 : 58)
    }

    private func toggle(_ track: Track) {
        if selection.contains(track.videoId) {
            selection.remove(track.videoId)
        } else {
            selection.insert(track.videoId)
        }
    }

    private func endSelection() {
        selecting = false
        selection = []
    }

    /// The picked tracks, in the order they're shown.
    private var selectedTracks: [Track] {
        guard let page else { return [] }
        return shownTracks(page).filter { selection.contains($0.videoId) }
    }

    private func removeSelected() {
        guard let pid = playlistId, !selection.isEmpty else { return }
        let batch = selectedTracks
        workingOnSelection = true
        Task {
            var removed = 0
            for track in batch {
                if (try? await YTM.shared.removeFromPlaylist(playlistId: pid,
                                                             videoId: track.videoId,
                                                             setVideoId: track.setVideoId)) == true {
                    removed += 1
                }
            }
            workingOnSelection = false
            if removed > 0 {
                player.showToast(removed == batch.count
                                 ? "Removed \(removed) song\(removed == 1 ? "" : "s")"
                                 : "Removed \(removed) of \(batch.count)")
                PageCache.shared.collections[cacheKey] = nil
                endSelection()
                await load()
            } else {
                player.showToast("Couldn't remove — you can only edit your own playlists")
            }
        }
    }

    private func load() async {
        if let cached = PageCache.shared.collections[cacheKey] { page = cached; applyDefaultSort(cached.tracks); loading = false }
        let fresh: CollectionPage?
        switch kind {
        case .album(let id): fresh = try? await YTM.shared.album(browseId: id)
        case .playlist(let id): fresh = try? await YTM.shared.playlist(id: id)
        case .podcast(let id): fresh = try? await YTM.shared.podcastShow(browseId: id)
        }
        if let fresh {
            page = fresh
            applyDefaultSort(fresh.tracks)
            PageCache.shared.collections[cacheKey] = fresh
            player.reconcileLikes(from: fresh.tracks)
        }
        loading = false
        await refreshSavedState()

        // Native names for the artists on this page (张学友, not "Jacky
        // Cheung"). Cached + persisted, so this only costs anything once.
        // Fed in chunks so the visible rows update while the rest of a long
        // playlist is still resolving, instead of everything landing at the
        // end (or, as before, never).
        if let page {
            let names = artistNames(in: page)
            for start in stride(from: 0, to: names.count, by: 24) {
                let chunk = Array(names[start..<min(start + 24, names.count)])
                if await NativeNames.warmUp(names: chunk) {
                    nameVersion &+= 1
                    player.nameVersion &+= 1
                }
                if Task.isCancelled { return }
            }
        }
    }

    /// Is this album in the library? Resolved against the library album list,
    /// which is authoritative — the page's own toggle menus are not (they read
    /// "Save album to library" even for albums already saved).
    private func refreshSavedState() async {
        guard case .album(let browseId) = kind else { return }
        guard let albums = try? await YTM.shared.libraryAlbums() else { return }
        page?.savedToLibrary = albums.contains { $0.browseId == browseId }
    }

    private func remove(_ track: Track) {
        guard case .playlist(let id) = kind else { return }
        Task {
            let ok = (try? await YTM.shared.removeFromPlaylist(playlistId: id, videoId: track.videoId,
                                                              setVideoId: track.setVideoId)) ?? false
            if ok, var updated = page {
                updated.tracks.removeAll { $0.videoId == track.videoId && $0.setVideoId == track.setVideoId }
                page = updated; PageCache.shared.collections[cacheKey] = updated
                player.showToast("Removed from playlist")
            } else { player.showToast("Couldn't remove — you can only edit your own playlists") }
        }
    }
}

// MARK: - Playlist edit sheet

struct PlaylistEditSheet: View {
    let playlistId: String
    @State var title: String
    @State var description: String
    var onSaved: (String, String) -> Void
    /// Called after a successful delete so the page can navigate away.
    var onDeleted: (() -> Void)? = nil

    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var privacy = "KEEP"
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Playlist name", text: $title)
                }
                Section("Description") {
                    TextField("Description", text: $description, axis: .vertical).lineLimit(3...6)
                }
                Section("Privacy") {
                    Picker("Privacy", selection: $privacy) {
                        Text("Keep current").tag("KEEP")
                        Text("Private").tag("PRIVATE")
                        Text("Public").tag("PUBLIC")
                        Text("Unlisted").tag("UNLISTED")
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Text("YouTube Music doesn't allow custom artwork for regular playlists — art is auto-generated from the tracks.")
                    .font(.footnote).foregroundStyle(Theme.textTertiary)
                Section {
                    Button("Delete Playlist…", role: .destructive) { confirmingDelete = true }
                        .disabled(saving)
                }
            }
            .alert("Delete “\(title)”?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deletePlaylist() }
            } message: {
                Text("This removes the playlist from your YouTube Music account for good — it can't be undone. The songs stay in your library.")
            }
            .navigationTitle("Edit Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        saving = true; error = nil
        let name = title.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = (try? await YTM.shared.editPlaylist(
                playlistId: playlistId, title: name, description: description,
                privacy: privacy == "KEEP" ? nil : privacy)) ?? false
            saving = false
            if ok {
                onSaved(name, description)
                player.showToast("Playlist updated")
                LibraryStore.shared.invalidate()
                dismiss()
            } else {
                error = "Couldn't save — you can only edit your own playlists."
            }
        }
    }

    private func deletePlaylist() {
        saving = true; error = nil
        Task {
            let ok = (try? await YTM.shared.deletePlaylist(playlistId: playlistId)) ?? false
            saving = false
            if ok {
                player.showToast("Deleted “\(title)”")
                PageCache.shared.collections["playlist-\(playlistId)"] = nil
                LibraryStore.shared.invalidate()
                onDeleted?()
                dismiss()
            } else {
                error = "Couldn't delete — you can only delete your own playlists."
            }
        }
    }
}

// MARK: - Podcast (Apple Podcasts–style show page)

struct PodcastScreen: View {
    let browseId: String

    @EnvironmentObject var player: PlayerEngine
    @State private var page: CollectionPage?
    @State private var loading = true
    @State private var descExpanded = false
    @State private var newestFirst = true
    @State private var playedIds: Set<String> = []

    private var cacheKey: String { "podcast-\(browseId)" }
    private var sortKey: String { "podsort-\(browseId)" }

    private var episodes: [Track] {
        guard let page else { return [] }
        return newestFirst ? page.tracks : page.tracks.reversed()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let page {
                    header(page)
                    HStack {
                        Text("Episodes").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Menu {
                            Button { newestFirst = true } label: {
                                if newestFirst { Label("Recent", systemImage: "checkmark") } else { Text("Recent") }
                            }
                            Button { newestFirst = false } label: {
                                if !newestFirst { Label("Oldest", systemImage: "checkmark") } else { Text("Oldest") }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(newestFirst ? "Recent" : "Oldest").font(.system(size: 13, weight: .medium))
                                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                            }.foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 4)

                    // One decode of the progress map per render, not per row.
                    let progressMap = EpisodeProgress.all()
                    ForEach(Array(episodes.enumerated()), id: \.offset) { i, ep in
                        EpisodeRow(episode: ep,
                                   isCurrent: player.current?.videoId == ep.videoId,
                                   isPlayed: playedIds.contains(ep.videoId),
                                   progress: progressMap[ep.videoId],
                                   onTogglePlayed: { togglePlayed(ep) }) {
                            // Tapping the current episode toggles play/pause;
                            // tapping another starts the show from there.
                            if player.current?.videoId == ep.videoId {
                                player.togglePlay()
                            } else {
                                player.playCollection(episodes, startAt: i)
                            }
                        }
                        Divider().background(Theme.stroke).padding(.leading, 16)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                Color.clear.frame(height: 80)
            }
        }
        .background(Theme.bg)
        .navigationTitle(page?.title ?? "").navigationBarTitleDisplayMode(.inline)
        .task {
            newestFirst = UserDefaults.standard.object(forKey: sortKey) as? Bool ?? true
            playedIds = PlayedEpisodes.all()
            await load()
        }
        .onChange(of: newestFirst) { _, v in UserDefaults.standard.set(v, forKey: sortKey) }
    }

    private func togglePlayed(_ episode: Track) {
        PlayedEpisodes.toggle(episode.videoId)
        playedIds = PlayedEpisodes.all()
        // Marking played discards the resume point (Apple Podcasts behavior).
        if playedIds.contains(episode.videoId) { EpisodeProgress.clear(episode.videoId) }
    }

    private func header(_ page: CollectionPage) -> some View {
        VStack(spacing: 12) {
            ArtworkView(url: Artwork.upscale(page.thumbnailURL, to: 500), corner: 14)
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            Text(page.title).font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
            if !page.subtitle.isEmpty {
                Text(page.subtitle).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button { player.playCollection(episodes, startAt: 0) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button { player.playShuffled(episodes) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 16).padding(.top, 2)
            if let desc = page.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(desc).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(descExpanded ? nil : 3)
                    Text(descExpanded ? "less" : "more").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { descExpanded.toggle() } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private func load() async {
        if let cached = PageCache.shared.collections[cacheKey] { page = cached; loading = false }
        if let fresh = try? await YTM.shared.podcastShow(browseId: browseId) {
            page = fresh; PageCache.shared.collections[cacheKey] = fresh
        }
        loading = false
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var player: PlayerEngine
    let episode: Track
    let isCurrent: Bool
    let isPlayed: Bool
    /// Saved playback position, when the episode was left partway through.
    var progress: EpisodeProgressEntry? = nil
    let onTogglePlayed: () -> Void
    let onPlay: () -> Void

    private var progressFraction: Double? {
        guard !isPlayed, let p = progress, p.duration > 0, p.position > 5 else { return nil }
        return min(1, max(0, p.position / p.duration))
    }

    private var remainingLabel: String {
        guard let p = progress else { return "" }
        let minutes = Int((max(0, p.duration - p.position) / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes) min left"
    }

    private var titleColor: Color {
        if isCurrent { return Theme.accent }
        return isPlayed ? Theme.textTertiary : Theme.textPrimary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if isPlayed {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                }
                if let date = episode.dateText, !date.isEmpty {
                    Text((isPlayed ? "PLAYED · " : "") + date.uppercased())
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                } else if isPlayed {
                    Text("PLAYED").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
            Text(episode.title).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(titleColor).lineLimit(2)
            if let details = episode.details, !details.isEmpty {
                Text(details).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Button(action: onPlay) {
                    HStack(spacing: 7) {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                        if let frac = progressFraction {
                            // Partially played: a small bar + time left, like
                            // Apple Podcasts. Resumes from this spot on play.
                            ProgressView(value: frac)
                                .progressViewStyle(.linear)
                                .tint(Theme.accent)
                                .frame(width: 62)
                            Text(remainingLabel).font(.system(size: 12, weight: .medium))
                        } else if !episode.lengthText.isEmpty {
                            Text(episode.lengthText).font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(isPlayed && !isCurrent ? Theme.textSecondary : Theme.textPrimary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: onTogglePlayed) {
                    Image(systemName: isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isPlayed ? Theme.accent : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                Menu {
                    Button("Play") { onPlay() }
                    Button("Play Next") { player.playNext(episode) }
                    Button("Add to Queue") { player.addToQueue(episode) }
                    Button(isPlayed ? "Mark as Unplayed" : "Mark as Played") { onTogglePlayed() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 36)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Artist

struct ArtistScreen: View {
    let browseId: String
    @EnvironmentObject var player: PlayerEngine
    @State private var page: ArtistPage?
    @State private var libraryTracks: [Track] = []
    @State private var libraryExpanded = false
    @State private var artistSummary: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let page {
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: Artwork.upscale(page.heroURL, to: 800)) { phase in
                            if case .success(let img) = phase { img.resizable().aspectRatio(contentMode: .fill) }
                            else { Theme.card }
                        }
                        .frame(height: 240).frame(maxWidth: .infinity).clipped()
                        .overlay(LinearGradient(colors: [.clear, Theme.bg], startPoint: .center, endPoint: .bottom))
                        Text(page.name).font(.system(size: 30, weight: .heavy)).foregroundStyle(.white).padding(16)
                    }
                    if let artistSummary {
                        // Wikidata bio: birthplace · age · country · career start
                        // (+ members for bands).
                        Text(artistSummary)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                    }
                    if !libraryTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("In your playlists & likes").font(.system(size: 18, weight: .bold))
                                Text("\(libraryTracks.count) song\(libraryTracks.count == 1 ? "" : "s") from your collection")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            let shown = libraryExpanded ? libraryTracks : Array(libraryTracks.prefix(8))
                            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                                TrackRowView(track: t, onRemoveFromPlaylist: nil) {
                                    player.playCollection(libraryTracks, startAt: i)
                                }.padding(.horizontal, 16)
                            }
                            if libraryTracks.count > 8 {
                                Button {
                                    withAnimation { libraryExpanded.toggle() }
                                } label: {
                                    Text(libraryExpanded ? "Show less" : "Show all \(libraryTracks.count) songs")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 2)
                            }
                        }
                    }
                    ForEach(page.shelves) { ShelfRow(shelf: $0) }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                Color.clear.frame(height: 80)
            }
        }
        .background(Theme.bg).ignoresSafeArea(edges: .top)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        if let cached = PageCache.shared.artists[browseId] { page = cached; loading = false }
        if let fresh = try? await YTM.shared.artist(browseId: browseId) {
            page = fresh; PageCache.shared.artists[browseId] = fresh
            let all = await LibraryStore.shared.allKnownTracks()
            libraryTracks = all.filter {
                ArtistMatch.matches($0, browseId: browseId, pageName: fresh.name)
            }
            artistSummary = await ArtistInfo.summary(forName: fresh.name)
        }
        loading = false
    }
}

// MARK: - Browse (library-artist / generic)

struct BrowseScreen: View {
    let browseId: String
    @State private var title = ""
    @State private var shelves: [Shelf] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 80) }
                ForEach(shelves) { ShelfRow(shelf: $0) }
                Color.clear.frame(height: 80)
            }.padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task {
            if let p = try? await YTM.shared.browsePage(browseId: browseId) { title = p.title; shelves = p.shelves }
            loading = false
        }
    }
}

// MARK: - Most Played

/// The ranked play-count list. Shared by the Library ▸ Most Played tab and
/// the standalone screen, so the two can't drift.
struct MostPlayedList: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var records: [PlayRecord] = []

    private var tracks: [Track] { records.map(\.track) }

    var body: some View {
            LazyVStack(spacing: 0) {
                if records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar").font(.system(size: 36)).foregroundStyle(Theme.textTertiary)
                        Text("No plays yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        Text("Songs you play are ranked here by how many times you've listened.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    if tracks.count > 1 {
                        HStack(spacing: 10) {
                            Button { player.playCollection(tracks, startAt: 0) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            Button { player.playShuffled(tracks) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                        }.padding(16)
                    }
                    ForEach(Array(records.enumerated()), id: \.offset) { i, rec in
                        Button { player.playCollection(tracks, startAt: i) } label: {
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.system(size: 14, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.textTertiary).frame(width: 24, alignment: .trailing)
                                ArtworkView(url: rec.track.thumbnailURL, corner: 5).frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(NativeNames.displayTitle(rec.track.title)).font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(player.current?.videoId == rec.track.videoId ? Theme.accent : Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(rec.track.artistLine).font(.system(size: 12.5))
                                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(rec.count) play\(rec.count == 1 ? "" : "s")")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .task { records = PlayCounts.mostPlayed() }
    }
}

struct MostPlayedScreen: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                MostPlayedList()
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Most Played").navigationBarTitleDisplayMode(.inline)
    }
}
