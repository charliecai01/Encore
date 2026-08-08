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
                }
            }
        }
        .padding(.horizontal, 16)
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
    var onRemoveFromPlaylist: (() -> Void)?
    let onPlay: () -> Void
    @State private var played = false
    @State private var swipeOffset: CGFloat = 0

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
        .onTapGesture { if !track.isUnavailable { onPlay() } }
        .gesture(playNextSwipe)
        .onAppear { if PodcastFeature.enabled, track.isEpisode { played = PlayedEpisodes.isPlayed(track.videoId) } }
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
                Text(track.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(player.current?.videoId == track.videoId ? Theme.accent
                                     : (played ? Theme.textTertiary : Theme.textPrimary))
                    .lineLimit(1)
                Text(track.playsText.map { "\(track.artistLine) · \($0)" } ?? track.artistLine)
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
    /// Rows shown for a vertical song shelf before it's truncated. Enough to
    /// browse, short enough that the next shelf is still reachable by thumb.
    static let verticalTrackLimit = 12

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
                                        Text(track.title).font(.system(size: 13, weight: .semibold))
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

struct ExploreScreen: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var nav: Nav
    @State private var shelves: [Shelf] = []
    @State private var playlists: [CardItem] = []
    @State private var discoverShelf: Shelf?
    /// Latest episodes from subscribed shows (the "New Episodes" RDPN feed) —
    /// surfaced on Home because podcasts otherwise live two taps deep.
    @State private var podcastShelf: Shelf?
    /// R&B — Charlie's genre. iOS has no Explore tab, so it rides on Home:
    /// the long DJ remix mixes (videos) + YouTube's own "R&B & soul" shelves.
    @State private var rnbShelves: [Shelf] = []
    @State private var classicsShelves: [Shelf] = []
    @State private var loading = true
    @State private var editingShortcuts = false
    @State private var shortcutOrder: [String] = UserDefaults.standard.stringArray(forKey: "homeShortcutOrder") ?? []

    private let shortcutRowHeight: CGFloat = 76

    /// User's playlists in their saved shortcut order (reordered ones first,
    /// any new/unseen playlists appended in the server's order).
    private var orderedPlaylists: [CardItem] {
        guard !shortcutOrder.isEmpty else { return playlists }
        let known = Set(shortcutOrder)
        let ranked = shortcutOrder.compactMap { id in playlists.first { $0.id == id } }
        let rest = playlists.filter { !known.contains($0.id) }
        return ranked + rest
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Full-width quick-access shortcuts to your playlists. Tap Edit
                // to drag them into a custom order (persisted across launches).
                if !playlists.isEmpty {
                    HStack {
                        Spacer()
                        Button(editingShortcuts ? "Done" : "Edit") {
                            withAnimation { editingShortcuts.toggle() }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 16)

                    if editingShortcuts {
                        List {
                            ForEach(orderedPlaylists) { pl in
                                shortcutRow(pl)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                            .onMove(perform: moveShortcut)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .environment(\.editMode, .constant(.active))
                        .frame(height: CGFloat(orderedPlaylists.count) * (shortcutRowHeight + 8) + 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(orderedPlaylists) { pl in
                                Button { nav.open(pl) } label: { shortcutRow(pl) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                if let podcastShelf { ShelfRow(shelf: podcastShelf) }
                if let discoverShelf { ShelfRow(shelf: discoverShelf) }
                ForEach(rnbShelves) { ShelfRow(shelf: $0) }
                ForEach(classicsShelves) { ShelfRow(shelf: $0) }
                ForEach(shelves) { ShelfRow(shelf: $0) }
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Explore")
        .toolbar { accountButton }
        .refreshable { await load() }
        .task(id: auth.isSignedIn) { await load() }
    }

    private func load() async {
        loading = true
        // Seed instantly from the disk-backed cache (persists across launches),
        // then refresh from the network below.
        if let cached = PageCache.shared.shelves["home"], !cached.isEmpty { shelves = cached; loading = false }
        if playlists.isEmpty, !PageCache.shared.homePlaylists.isEmpty { playlists = PageCache.shared.homePlaylists }
        let fresh = (try? await YTM.shared.home()) ?? []
        if !fresh.isEmpty { shelves = fresh; PageCache.shared.shelves["home"] = fresh }
        loading = false
        // Load the user's saved playlists directly so the grid is independent
        // of shared-store timing.
        if auth.isSignedIn {
            var freshPlaylists = (try? await YTM.shared.libraryPlaylists()) ?? []
            // Pin subscribed shows (TheMove) ahead of the playlists — the
            // only podcast feed in use, one tap from Home.
            if PodcastFeature.enabled {
                let shows = ((try? await YTM.shared.libraryPodcasts()) ?? [])
                    .filter { $0.kind == .podcast }
                freshPlaylists = shows + freshPlaylists
            }
            if !freshPlaylists.isEmpty {
                playlists = freshPlaylists
                PageCache.shared.homePlaylists = freshPlaylists
            }
            // Latest episodes from subscribed shows ("New Episodes" / RDPN).
            if PodcastFeature.enabled {
                let episodes = ((try? await YTM.shared.playlist(id: "RDPN"))?.tracks ?? [])
                    .filter(\.isEpisode)
                if !episodes.isEmpty {
                    podcastShelf = Shelf(title: "New Podcast Episodes",
                                         items: episodes.prefix(8).map { .track($0) })
                }
            }
            await library.loadIfNeeded()
            let discover = await library.discover()
            if !discover.isEmpty {
                discoverShelf = Shelf(title: "Discover · Fresh for you", items: discover.map { .card($0.asSongCard) })
            }
        }
        await loadRnB()
    }

    /// R&B section (no sign-in needed): the long DJ remix mixes that only
    /// exist as videos, then YouTube Music's own "R&B & soul" shelves.
    private func loadRnB() async {
        async let remixTask = (try? await YTM.shared.search("R&B remix mix", filter: .videos))?
            .shelves.flatMap(\.items) ?? []
        async let genreTask = (try? await YTM.shared.genre(params: YTM.Genre.rnbParams)) ?? []

        // Order matches macOS Explore: the "R&B & soul" song shelves lead,
        // then the long DJ remix mixes. (macOS gets this by inserting the
        // genre shelves at 0 *after* the remixes; iOS builds the list
        // directly, so keep the two in step if either changes.)
        // These pages are editorial and barely change, so rotate weekly rather
        // than staring at the same lead track for days.
        var built: [Shelf] = []
        for shelf in WeeklyRotation.rotateItems(in: Array(await genreTask.prefix(4)))
        where !shelf.items.isEmpty {
            built.append(Shelf(title: shelf.title.localizedCaseInsensitiveContains("r&b")
                               ? shelf.title : "R&B · \(shelf.title)",
                               items: shelf.items, moreBrowseId: shelf.moreBrowseId))
        }
        // Rotate BEFORE trimming, so the 15 shown are a different slice each
        // week rather than the same 15 reordered.
        let remixes = WeeklyRotation.rotate(await remixTask)
        if !remixes.isEmpty {
            built.append(Shelf(title: "R&B Remixes & DJ Mixes", items: Array(remixes.prefix(15))))
        }
        if !built.isEmpty { rnbShelves = built }

        let classics = (try? await YTM.shared.classics()) ?? []
        if !classics.isEmpty { classicsShelves = WeeklyRotation.rotateItems(in: classics) }
    }

    /// One full-width shortcut box (artwork + title).
    @ViewBuilder private func shortcutRow(_ pl: CardItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: pl.thumbnailURL, corner: 6).frame(width: 60, height: 60)
            Text(pl.title).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: shortcutRowHeight, maxHeight: shortcutRowHeight, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func moveShortcut(from source: IndexSet, to destination: Int) {
        var items = orderedPlaylists
        items.move(fromOffsets: source, toOffset: destination)
        shortcutOrder = items.map(\.id)
        UserDefaults.standard.set(shortcutOrder, forKey: "homeShortcutOrder")
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
                if auth.isSignedIn, PlayCountsFeature.enabled {
                    Button { nav.go(.mostPlayed) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.bar.fill").font(.system(size: 15))
                                .foregroundStyle(Theme.accent).frame(width: 26)
                            Text("Most Played").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Picker("", selection: $tab) {
                    ForEach(LibraryTab.visible, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if auth.isSignedIn && !loading {
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
        .refreshable { await load() }
        .task(id: "\(auth.isSignedIn)-\(tab.rawValue)") { restoreSort(); await load() }
        .onChange(of: songSort) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "sort-lib-songs") }
        .onChange(of: cardSort) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "sort-lib-\(tab.rawValue)") }
    }

    private func restoreSort() {
        if let s = UserDefaults.standard.string(forKey: "sort-lib-songs").flatMap(SortMode.init) { songSort = s }
        if let s = UserDefaults.standard.string(forKey: "sort-lib-\(tab.rawValue)").flatMap(SortMode.init) { cardSort = s }
        else { cardSort = .recent }
    }

    private func load() async {
        guard auth.isSignedIn else { return }
        loading = true
        switch tab {
        case .playlists: cards = (try? await YTM.shared.libraryPlaylists()) ?? []
        case .songs: tracks = await LibraryStore.shared.allKnownTracks()
        case .albums: cards = (try? await YTM.shared.libraryAlbums()) ?? []
        case .artists:
            let corpus = (try? await YTM.shared.libraryArtists()) ?? []
            let all = await LibraryStore.shared.allKnownTracks()
            cards = Self.artistCards(corpus: corpus, tracks: all)
        case .podcasts:
            cards = (try? await YTM.shared.libraryPodcasts()) ?? []
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
    private func shownTracks(_ page: CollectionPage) -> [Track] {
        TrackSort.apply(page.tracks, filter: filter, sort: sort, keepOrder: sort == .recent)
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
                if let page {
                    ArtworkView(url: Artwork.upscale(page.thumbnailURL, to: 500), corner: 12)
                        .frame(width: 140, height: 140).frame(maxWidth: .infinity)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 6).padding(.top, 8)
                    VStack(spacing: 4) {
                        Text(page.title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
                        if !page.subtitle.isEmpty {
                            Text(page.subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                    }.frame(maxWidth: .infinity)
                    let shown = shownTracks(page)
                    HStack(spacing: 10) {
                        Button { player.playCollection(shown, startAt: 0, playlistId: playlistId) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button { player.playShuffled(shown, playlistId: playlistId) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }.padding(.horizontal, 16)
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
                                         onRemoveFromPlaylist: isPlaylist ? { remove(t) } : nil) {
                                player.playCollection(shown, startAt: i, playlistId: playlistId)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                Color.clear.frame(height: 80)
            }
        }
        .background(Theme.bg)
        .navigationTitle(page?.title ?? "").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPlaylist, page != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showEdit = true } label: { Image(systemName: "pencil") }
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

    private func load() async {
        if let cached = PageCache.shared.collections[cacheKey] { page = cached; applyDefaultSort(cached.tracks); loading = false }
        let fresh: CollectionPage?
        switch kind {
        case .album(let id): fresh = try? await YTM.shared.album(browseId: id)
        case .playlist(let id): fresh = try? await YTM.shared.playlist(id: id)
        case .podcast(let id): fresh = try? await YTM.shared.podcastShow(browseId: id)
        }
        if let fresh { page = fresh; applyDefaultSort(fresh.tracks); PageCache.shared.collections[cacheKey] = fresh }
        loading = false
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

struct MostPlayedScreen: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var records: [PlayRecord] = []

    private var tracks: [Track] { records.map(\.track) }

    var body: some View {
        ScrollView {
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
                                    Text(rec.track.title).font(.system(size: 15, weight: .medium))
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
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Most Played").navigationBarTitleDisplayMode(.inline)
        .task { records = PlayCounts.mostPlayed() }
    }
}
