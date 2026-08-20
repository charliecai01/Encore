import SwiftUI
import EncoreCore

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
                Text(track.rowSubtitle(fallbackArtist: fallbackArtist))
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
            // Ordered/grouped to match the macOS context menu (Charlie,
            // 2026-08-20) — same sections in the same sequence: playback,
            // radio/share, add-to-playlist, navigation, liked/remove. Share
            // and the podcast played-toggle are iOS-only additions, slotted
            // into the section they thematically belong with.
            Menu {
                Button("Play") { onPlay() }
                Button("Play Next") { player.playNext(track) }
                Button("Add to Queue") { player.addToQueue(track) }
                if PodcastFeature.enabled, track.isEpisode {
                    Button(played ? "Mark as Unplayed" : "Mark as Played") {
                        PlayedEpisodes.toggle(track.videoId)
                        played = PlayedEpisodes.isPlayed(track.videoId)
                    }
                }
                Divider()
                Button("Start Radio") { player.playRadio(from: track) }
                if let url = track.shareURL {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button {
                        UIPasteboard.general.url = url
                    } label: { Label("Copy Link", systemImage: "link") }
                }
                Divider()
                Button("Add to Playlist") { showAddToPlaylist = true }
                Divider()
                if let albumId = track.album?.id {
                    Button("Go to Album") { nav.go(.album(albumId)) }
                }
                if let a = track.artists.first {
                    Button("Go to Artist") { nav.goArtist(id: a.id, name: a.name) }
                }
                Divider()
                Button(player.likedIds.contains(track.videoId) ? "Remove from Liked" : "Add to Liked") {
                    player.toggleLike(track)
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
