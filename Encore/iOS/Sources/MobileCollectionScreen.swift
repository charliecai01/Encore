import SwiftUI
import EncoreCore

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
        artistNameCandidates(in: shownTracks(page), headerArtist: headerArtist(of: page))
    }

    /// The artist an album page is billed to. nil for playlists, which are
    /// billed to their owner rather than an artist.
    private func headerArtist(of page: CollectionPage) -> String? {
        page.headerArtist(isAlbum: isAlbum)
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
        let fallback = headerArtist(of: page)
        let year = page.headerYear(isAlbum: isAlbum)
        let available = page.tracks.filter { !$0.isUnavailable }
            .map { $0.withFallbackArtist(fallback, ref: page.headerArtistRef).withYear(year) }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                selectionBar
            } else {
                // Reserve space for the floating MiniPlayer overlay (MobileRoot),
                // which sits outside this NavigationStack's safe area and would
                // otherwise cover the last row(s) of a long track list.
                Color.clear.frame(height: player.current != nil ? 118 : 58)
            }
        }
        .navigationTitle(page?.title ?? "").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let page {
                if selecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { endSelection() }
                    }
                } else {
                    // Play/Shuffle/Save moved up into the nav bar itself,
                    // level with the pencil menu (Charlie, 2026-09-02) —
                    // previously their own row below the title. Declared in
                    // this order so the pencil, added last, lands rightmost
                    // (closest to the edge), matching where it always sat.
                    let shown = shownTracks(page)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { player.playCollection(shown, startAt: 0, playlistId: playlistId) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Theme.accent, in: Circle())
                        }
                        .accessibilityLabel("Play")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { player.playShuffled(shown, playlistId: playlistId) } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 30, height: 30)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.stroke))
                        }
                        .accessibilityLabel("Shuffle")
                    }
                    // Albums carry a library toggle; playlists don't.
                    if let saved = page.savedToLibrary, let target = page.libraryTargetPlaylistId {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { setSaved(!saved, target: target) } label: {
                                Image(systemName: saved ? "checkmark" : "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 30, height: 30)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().strokeBorder(Theme.stroke))
                            }
                            .disabled(savingToLibrary)
                            .opacity(savingToLibrary ? 0.5 : 1)
                            .accessibilityLabel(saved ? "Remove album from library" : "Save album to library")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
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
