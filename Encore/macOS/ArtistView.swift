import SwiftUI
import EncoreCore

struct ArtistView: View {
    @EnvironmentObject var player: PlayerEngine

    let browseId: String

    @State private var page: ArtistPage?
    @State private var loading = true
    @State private var error: String?
    @State private var libraryTracks: [Track] = []
    @State private var showAllLibrary = false
    @State private var scanningLibrary = false
    @State private var artistSummary: String?

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
                    VStack(alignment: .leading, spacing: 26) {
                        hero(page)
                        if let artistSummary {
                            // Wikidata bio: birthplace · age · country · career
                            // start (+ members for bands).
                            Text(artistSummary)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 24)
                        }
                        if scanningLibrary && libraryTracks.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Checking your playlists…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 24)
                        }
                        if !libraryTracks.isEmpty {
                            librarySection
                        }
                        ForEach(visibleShelves(page)) { shelf in
                            ShelfView(shelf: shelf)
                        }
                    }
                    .padding(.bottom, 36)
                }
            }
        }
        .task { await load() }
    }

    /// Shelves YouTube returns that Charlie doesn't want shown here
    /// (2026-08-20): "Playlists by [name]" (community playlists, low
    /// signal), "Featured on" (YouTube's own curated playlists), and "From
    /// your library" — redundant with `librarySection` above, which has
    /// Play/Shuffle and full track rows this shelf doesn't. The "About"
    /// section (page.description) is gone too — the Wikidata `artistSummary`
    /// at the top is Charlie's own "About" now.
    private func visibleShelves(_ page: ArtistPage) -> [Shelf] {
        page.shelves.filter { shelf in
            !shelf.title.hasPrefix("Playlists by")
                && shelf.title != "Featured on"
                && shelf.title != "From your library"
        }
    }

    private func hero(_ page: ArtistPage) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: Artwork.upscale(page.heroURL, to: 1200)) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.card
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                LinearGradient(colors: [.clear, Theme.bg.opacity(0.55), Theme.bg],
                               startPoint: .top, endPoint: .bottom)
            )

            VStack(alignment: .leading, spacing: 12) {
                Text(page.name)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                HStack(spacing: 10) {
                    if page.shuffleVideoId != nil || page.shufflePlaylistId != nil {
                        PillButton(title: "Shuffle", icon: "shuffle", prominent: true) {
                            shufflePlay(page)
                        }
                    }
                    if let radioId = page.radioPlaylistId {
                        PillButton(title: "Radio", icon: "dot.radiowaves.left.and.right") {
                            player.playStation(playlistId: radioId, title: "\(page.name) Radio")
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    /// Spotify-style: your liked songs by this artist, right on their page.
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In your playlists & likes")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(libraryTracks.count) song\(libraryTracks.count == 1 ? "" : "s") from your collection")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                PillButton(title: "Play All", icon: "play.fill") {
                    player.playCollection(libraryTracks, startAt: 0)
                }
                PillButton(title: "Shuffle", icon: "shuffle") {
                    player.playShuffled(libraryTracks)
                }
            }
            .padding(.horizontal, 24)

            let shown = showAllLibrary ? libraryTracks : Array(libraryTracks.prefix(5))
            LazyVStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, track in
                    TrackRow(track: track, showsAlbum: true) {
                        player.playCollection(libraryTracks, startAt: i)
                    }
                }
            }
            .padding(.horizontal, 12)

            if libraryTracks.count > 5 {
                Button(showAllLibrary ? "Show less" : "Show all \(libraryTracks.count)") {
                    withAnimation { showAllLibrary.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 24)
            }
        }
    }

    private func shufflePlay(_ page: ArtistPage) {
        Task {
            if let result = try? await YTM.shared.queue(videoId: page.shuffleVideoId,
                                                        playlistId: page.shufflePlaylistId),
               !result.tracks.isEmpty {
                player.playCollection(result.tracks, startAt: result.currentIndex)
            } else if let topSongs = page.shelves.first(where: { $0.isTrackShelf }) {
                player.playShuffled(topSongs.tracks)
            }
        }
    }

    private func load() async {
        if let cached = PageCache.shared.artists[browseId] {
            page = cached
            loading = false
            await loadLibraryTracks(artistName: cached.name)
            artistSummary = await ArtistInfo.summary(forName: cached.name)
            return
        }
        loading = true
        error = nil
        do {
            let result = try await YTM.shared.artist(browseId: browseId)
            page = result
            PageCache.shared.artists[browseId] = result
            loading = false
            await loadLibraryTracks(artistName: result.name)
            artistSummary = await ArtistInfo.summary(forName: result.name)
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    /// Everything by this artist across liked songs AND all library playlists.
    private func loadLibraryTracks(artistName: String) async {
        scanningLibrary = true
        let all = await LibraryStore.shared.allKnownTracks()
        // Shared matcher: id arm (incl. MPLA alias) + per-name matching that
        // survives combined page titles like "陶喆 - David Tao".
        libraryTracks = all.filter {
            ArtistMatch.matches($0, browseId: browseId, pageName: artistName)
        }
        scanningLibrary = false
    }
}
