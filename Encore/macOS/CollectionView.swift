import SwiftUI
import EncoreCore

/// Album and playlist detail page with an artwork-tinted hero header.
struct CollectionView: View {
    enum Kind {
        case album(String)
        case playlist(String)
        case podcast(String)

        var label: String {
            switch self {
            case .album: return "Album"
            case .playlist: return "Playlist"
            case .podcast: return "Podcast"
            }
        }
    }

    @EnvironmentObject var player: PlayerEngine

    let kind: Kind

    @State private var page: CollectionPage?
    @State private var loading = true
    @State private var error: String?
    @State private var palette = Palette.fallback
    @State private var sort: CollectionSort = .order
    @State private var filterText = ""
    @State private var showEdit = false
    @State private var appliedDefaultSort = false

    /// "Plays" only makes sense on play-count-ranked lists (e.g. Top songs).
    private var availableSorts: [CollectionSort] {
        let hasPlays = page.map { LibrarySort.hasPlayCounts($0.tracks) } ?? false
        return CollectionSort.allCases.filter { option in
            switch option {
            case .plays: return hasPlays            // global counts (Top songs)
            case .mostPlayed, .leastPlayed: return PlayCountsFeature.enabled
            default: return true
            }
        }
    }

    /// Default a play-count-ranked playlist (artist Top songs) to the Plays sort,
    /// once, so it opens highest → lowest without overriding later user choices.
    private func applyDefaultSort(_ tracks: [Track]) {
        guard isPlaylist, !appliedDefaultSort, !tracks.isEmpty else { return }
        appliedDefaultSort = true
        if LibrarySort.hasPlayCounts(tracks) { sort = .plays }
    }

    enum CollectionSort: String, CaseIterable {
        case order = "Playlist Order"
        case added = "Recently Added"
        case title = "Title"
        case artist = "Artist"
        case album = "Album"
        /// YouTube's global play count (artist Top songs).
        case plays = "Plays"
        /// YOUR play counts (PlayCounts); Least Played surfaces never-played.
        case mostPlayed = "Most Played"
        case leastPlayed = "Least Played"
    }

    private var sortStorageKey: String {
        switch kind {
        case .album(let id): return "sort-album-\(id)"
        case .playlist(let id): return "sort-playlist-\(id)"
        case .podcast(let id): return "sort-podcast-\(id)"
        }
    }

    private func visibleTracks(_ page: CollectionPage) -> [Track] {
        let order: TrackOrder
        switch sort {
        case .order: order = .source
        case .added: order = .reversed   // no per-track date; newest-first by position
        case .title: order = .title
        case .artist: order = .artist
        case .album: order = .album
        case .plays: order = .plays
        case .mostPlayed: order = .mostPlayed
        case .leastPlayed: order = .leastPlayed
        }
        return LibrarySort.arrange(page.tracks, query: filterText, order: order)
    }

    var body: some View {
        Group {
            if loading {
                LoadingView()
            } else if let error {
                ErrorView(message: error) {
                    Task { await load() }
                }
            } else if let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(page)
                        controls
                            .padding(.horizontal, 24)
                            .padding(.top, 18)
                        trackList(page)
                            .padding(.top, 10)
                            .padding(.bottom, 36)
                    }
                }
                .background(alignment: .top) {
                    LinearGradient(colors: [palette.dim, Theme.bg],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 420)
                        .allowsHitTesting(false)
                }
            }
        }
        .task {
            // Playlists always open sorted by artist.
            if isPlaylist {
                sort = .artist
            } else if let saved = UserDefaults.standard.string(forKey: sortStorageKey),
                      let savedSort = CollectionSort(rawValue: saved) {
                sort = savedSort
            }
            await load()
        }
        .onChange(of: sort) { _, newSort in
            // Don't persist for playlists — they should reopen sorted by artist.
            if !isPlaylist { UserDefaults.standard.set(newSort.rawValue, forKey: sortStorageKey) }
        }
        .sheet(isPresented: $showEdit) {
            if case .playlist(let id) = kind, let page {
                PlaylistEditSheet(playlistId: id, title: page.title, description: page.description ?? "") { newTitle, newDesc in
                    if var updated = self.page {
                        updated.title = newTitle; updated.description = newDesc
                        self.page = updated; PageCache.shared.collections[cacheKey] = updated
                    }
                }
            }
        }
    }

    private func header(_ page: CollectionPage) -> some View {
        HStack(alignment: .bottom, spacing: 22) {
            ArtworkView(url: Artwork.upscale(page.thumbnailURL, to: 544), corner: 10)
                .frame(width: 212, height: 212)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)

            VStack(alignment: .leading, spacing: 9) {
                Text(kind.label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .kerning(1)
                Text(page.title)
                    .font(.system(size: page.title.count > 28 ? 26 : 36, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !page.subtitle.isEmpty {
                    Text(page.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if !page.secondSubtitle.isEmpty {
                    Text(page.secondSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }

                HStack(spacing: 10) {
                    PillButton(title: "Play", icon: "play.fill", prominent: true) {
                        let shown = visibleTracks(page)
                        player.playCollection(shown, startAt: 0)
                    }
                    PillButton(title: "Shuffle", icon: "shuffle") {
                        player.playShuffled(visibleTracks(page))
                    }
                    if let first = page.tracks.first {
                        PillButton(title: "Radio", icon: "dot.radiowaves.left.and.right") {
                            player.playRadio(from: first)
                        }
                    }
                    if isPlaylist {
                        PillButton(title: "Edit", icon: "pencil") { showEdit = true }
                    }
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 220)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))

            if !isAlbum {
                Menu {
                    ForEach(availableSorts, id: \.self) { option in
                        Button {
                            sort = option
                        } label: {
                            if sort == option {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(sort.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
        }
    }

    private func trackList(_ page: CollectionPage) -> some View {
        let shown = visibleTracks(page)
        // Snapshot once per render — PlayCounts.all() decodes UserDefaults.
        let showPlayCounts = isPlaylist && PlayCountsFeature.enabled
        let counts = showPlayCounts ? PlayCounts.all() : [:]
        return LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, track in
                TrackRow(track: track,
                         index: i,
                         showsArtwork: !isAlbum,
                         showsAlbum: !isAlbum,
                         playCount: showPlayCounts ? (counts[track.videoId]?.count ?? 0) : nil,
                         onRemoveFromPlaylist: isPlaylist ? { removeTrack(track) } : nil) {
                    player.playCollection(shown, startAt: i)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func removeTrack(_ track: Track) {
        guard case .playlist(let playlistId) = kind else { return }
        Task {
            let ok = (try? await YTM.shared.removeFromPlaylist(playlistId: playlistId,
                                                               videoId: track.videoId,
                                                               setVideoId: track.setVideoId)) ?? false
            guard ok else {
                player.showToast("Couldn't remove — you can only edit your own playlists")
                return
            }
            if var updated = page {
                updated.tracks.removeAll {
                    $0.videoId == track.videoId && $0.setVideoId == track.setVideoId
                }
                page = updated
                PageCache.shared.collections[cacheKey] = updated
            }
            player.showToast("Removed from playlist")
        }
    }

    private var isAlbum: Bool {
        if case .album = kind { return true }
        return false
    }

    private var isPlaylist: Bool {
        if case .playlist = kind { return true }
        return false
    }

    private var cacheKey: String {
        switch kind {
        case .album(let id): return "album-\(id)"
        case .playlist(let id): return "playlist-\(id)"
        case .podcast(let id): return "podcast-\(id)"
        }
    }

    private func load() async {
        // Serve from the session cache instantly, then refresh silently.
        if let cached = PageCache.shared.collections[cacheKey] {
            page = cached
            applyDefaultSort(cached.tracks)
            loading = false
            palette = await ArtworkPalette.shared.palette(for: Artwork.upscale(cached.thumbnailURL, to: 336))
            if let fresh = try? await fetchPage() {
                page = fresh
                applyDefaultSort(fresh.tracks)
                PageCache.shared.collections[cacheKey] = fresh
            }
            return
        }
        loading = true
        error = nil
        do {
            let result = try await fetchPage()
            page = result
            applyDefaultSort(result.tracks)
            PageCache.shared.collections[cacheKey] = result
            loading = false
            palette = await ArtworkPalette.shared.palette(for: Artwork.upscale(result.thumbnailURL, to: 336))
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func fetchPage() async throws -> CollectionPage {
        switch kind {
        case .album(let browseId):
            return try await YTM.shared.album(browseId: browseId)
        case .playlist(let id):
            return try await YTM.shared.playlist(id: id)
        case .podcast(let browseId):
            return try await YTM.shared.podcastShow(browseId: browseId)
        }
    }
}
