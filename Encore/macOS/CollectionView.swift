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
    /// Bumped when native artist names finish resolving, purely to re-render.
    @State private var nameVersion = 0
    /// Multi-select: pick songs to remove from this playlist, or add to
    /// another. Holds videoIds.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var workingOnSelection = false
    @State private var sort: CollectionSort = .order
    @State private var filterText = ""
    @State private var showEdit = false
    @State private var appliedDefaultSort = false
    @State private var savingToLibrary = false

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
                PageCache.shared.collections[cacheKey] = page
            } catch {
                page?.savedToLibrary = !saved
                player.showToast("Couldn't update your library")
            }
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
        // Unavailable tracks are HIDDEN, not dimmed (Charlie, 2026-08-16).
        // Self-healing: `isUnavailable` is re-read on every load, so a track
        // that stops being greyed out reappears on the next fetch.
        let available = page.tracks.filter { !$0.isUnavailable }
        return LibrarySort.arrange(available, query: filterText, order: order)
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
                // Pinned copy of the Edit control: the header scrolls away on
                // a long playlist, and Select/Edit shouldn't mean scrolling
                // back to the top (Charlie, 2026-08-16). Sits OUTSIDE the
                // ScrollView so it stays put.
                .overlay(alignment: .topTrailing) {
                    editControl
                        .padding(.trailing, 24)
                        .padding(.top, 14)
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
                PlaylistEditSheet(playlistId: id, title: page.title, description: page.description ?? "",
                                  onSaved: { newTitle, newDesc in
                    if var updated = self.page {
                        updated.title = newTitle; updated.description = newDesc
                        self.page = updated; PageCache.shared.collections[cacheKey] = updated
                    }
                }, onDeleted: {
                    // The page no longer exists — go home.
                    Nav.shared.go(.home)
                })
            }
        }
    }

    private func header(_ page: CollectionPage) -> some View {
        // Playlist art is SHRUNK here, not removed (Charlie, 2026-08-14):
        // it's auto-generated and was dominating the header. Albums keep
        // theirs full size — that's real cover art. (iOS drops it entirely on
        // both; the phone has far less room.)
        HStack(alignment: .bottom, spacing: 22) {
            // Playlist art is sized to the text column so its top lines up
            // with the "PLAYLIST" label; albums keep the larger cover.
            let artSize: CGFloat = isPlaylist ? 150 : 212
            ArtworkView(url: Artwork.upscale(page.thumbnailURL, to: isPlaylist ? 240 : 544), corner: 10)
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.45), radius: isPlaylist ? 12 : 24, y: isPlaylist ? 5 : 10)

            VStack(alignment: .leading, spacing: 9) {
                Text(kind.label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .kerning(1)
                Text(page.title)
                    .font(.system(size: page.title.count > 28 ? 26 : 36, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !page.subtitle.isEmpty, !isPlaylist {
                    Text(page.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                // Playlists drop the view count — it's your own list, and
                // "8.4K views" says nothing next to tracks/duration. Albums
                // keep the line as YouTube sends it.
                let stats = isPlaylist ? DisplayText.withoutViewCount(page.secondSubtitle)
                                       : page.secondSubtitle
                if !stats.isEmpty {
                    Text(stats)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }

                HStack(spacing: 10) {
                    PillButton(title: "Play", icon: "play.fill", prominent: true) {
                        let shown = visibleTracks(page)
                        player.playCollection(shown, startAt: 0, playlistId: playlistContextId)
                    }
                    PillButton(title: "Shuffle", icon: "shuffle") {
                        player.playShuffled(visibleTracks(page), playlistId: playlistContextId)
                    }
                    if let first = page.tracks.first {
                        PillButton(title: "Radio", icon: "dot.radiowaves.left.and.right") {
                            player.playRadio(from: first)
                        }
                    }
                    // Albums carry a library toggle; playlists don't (savedToLibrary is nil).
                    if let saved = page.savedToLibrary, let target = page.libraryTargetPlaylistId {
                        PillButton(title: saved ? "Saved" : "Save",
                                   icon: saved ? "checkmark" : "plus") {
                            setSaved(!saved, target: target)
                        }
                        .disabled(savingToLibrary)
                    }
                }
                .padding(.top, 6)

                if selecting { selectionBar }
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
                         nameVersion: nameVersion,
                         isSelecting: selecting,
                         isSelected: selection.contains(track.videoId),
                         onRemoveFromPlaylist: isPlaylist ? { removeTrack(track) } : nil) {
                    if selecting {
                        toggleSelection(track)
                    } else {
                        player.playCollection(shown, startAt: i, playlistId: playlistContextId)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// One compact control rather than separate Edit and Select pills: the
    /// header row feeds the window's minimum width (EncoreApp pins minWidth
    /// 1264), and an extra pill pushed the window wider than the screen,
    /// clipping the player bar at both edges.
    @ViewBuilder private var editControl: some View {
        if selecting {
            PillButton(title: "Done", icon: "checkmark") {
                selecting = false; selection = []
            }
        } else {
            Menu {
                Button("Select Songs") { selecting = true; selection = [] }
                if isPlaylist {
                    Button("Edit Details…") { showEdit = true }
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Actions for the picked songs: add them to another playlist, or remove
    /// them from this one (playlists you own only).
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "Select songs" : "\(selection.count) selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Menu("Add to Playlist") {
                ForEach(editablePlaylists) { playlist in
                    Button(playlist.title) { addSelected(to: playlist) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(selection.isEmpty || workingOnSelection || editablePlaylists.isEmpty)

            if isPlaylist {
                PillButton(title: "Remove", icon: "trash") { removeSelected() }
                    .disabled(selection.isEmpty || workingOnSelection)
            }
        }
        .padding(.top, 4)
    }

    /// Playlists you can actually add to — Liked Music and auto-radios out.
    private var editablePlaylists: [CardItem] {
        LibraryStore.shared.playlists.filter { pl in
            guard let id = pl.playlistId else { return false }
            return id != "LM" && !id.hasPrefix("RD")
        }
    }

    private var selectedTracks: [Track] {
        guard let page else { return [] }
        return visibleTracks(page).filter { selection.contains($0.videoId) }
    }

    private func toggleSelection(_ track: Track) {
        if selection.contains(track.videoId) {
            selection.remove(track.videoId)
        } else {
            selection.insert(track.videoId)
        }
    }

    private func addSelected(to playlist: CardItem) {
        guard let pid = playlist.playlistId else { return }
        let batch = selectedTracks
        workingOnSelection = true
        Task {
            // Skip anything the target playlist already has — YouTube itself
            // allows the duplicate.
            let existing = (try? await YTM.shared.playlist(id: pid).tracks) ?? []
            let split = PlaylistAdd.split(batch, existing: existing)

            var added = 0, failed = 0
            for track in split.toAdd {
                if (try? await YTM.shared.addToPlaylist(playlistId: pid, videoId: track.videoId)) == true {
                    added += 1
                } else {
                    failed += 1
                }
            }
            workingOnSelection = false
            player.showToast(PlaylistAdd.resultMessage(added: added,
                                                       duplicates: split.duplicates.count,
                                                       failed: failed,
                                                       playlistTitle: playlist.title))
            if added > 0 { PageCache.shared.collections["playlist-\(pid)"] = nil }
            selecting = false
            selection = []
        }
    }

    private func removeSelected() {
        guard case .playlist(let pid) = kind, !selection.isEmpty else { return }
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
                selecting = false
                selection = []
                await load()
            } else {
                player.showToast("Couldn't remove — you can only edit your own playlists")
            }
        }
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

    /// The playlist id to hand the engine, so "Remove from Playlist" in the
    /// player bar knows which playlist the song is playing from. nil for
    /// albums and podcasts.
    private var playlistContextId: String? {
        if case .playlist(let id) = kind { return id }
        return nil
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

    /// Is this album in the library? Resolved against the library album list,
    /// which is authoritative — the page's own toggle menus are not (they read
    /// "Save album to library" even for albums already saved).
    private func refreshSavedState() async {
        guard case .album(let browseId) = kind else { return }
        guard let albums = try? await YTM.shared.libraryAlbums() else { return }
        page?.savedToLibrary = albums.contains { $0.browseId == browseId }
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
                player.reconcileLikes(from: fresh.tracks)
            }
            await refreshSavedState()
            return
        }
        loading = true
        error = nil
        do {
            let result = try await fetchPage()
            page = result
            applyDefaultSort(result.tracks)
            PageCache.shared.collections[cacheKey] = result
            player.reconcileLikes(from: result.tracks)
            loading = false
            palette = await ArtworkPalette.shared.palette(for: Artwork.upscale(result.thumbnailURL, to: 336))
            await refreshSavedState()
            // Native names for every artist on the page, in DISPLAYED order
            // so what's on screen resolves first. Walks the whole list — a
            // 692-track playlist has far more artists than one screenful, and
            // capping this left the songs further down romanized. Chunked so
            // rows update as it goes rather than all at the end.
            var names: [String] = []
            var seen = Set<String>()
            for track in visibleTracks(result) {
                for name in track.artists.map(\.name) + [track.artistLine]
                where !name.isEmpty && seen.insert(name).inserted {
                    names.append(name)
                }
            }
            for start in stride(from: 0, to: names.count, by: 24) {
                let chunk = Array(names[start..<min(start + 24, names.count)])
                if await NativeNames.warmUp(names: chunk) {
                    nameVersion &+= 1
                    player.nameVersion &+= 1
                }
                if Task.isCancelled { return }
            }
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
