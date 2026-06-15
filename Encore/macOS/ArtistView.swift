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
                        ForEach(page.shelves) { shelf in
                            ShelfView(shelf: shelf)
                        }
                        if let description = page.description, !description.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("About")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(description)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineSpacing(4)
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.bottom, 36)
                }
            }
        }
        .task { await load() }
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
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    /// Everything by this artist across liked songs AND all library playlists.
    private func loadLibraryTracks(artistName: String) async {
        scanningLibrary = true
        let all = await LibraryStore.shared.allKnownTracks()
        var mine = all.filter { track in
            track.artists.contains { $0.id == browseId }
        }
        if !artistName.isEmpty {
            let normalizedName = artistName.matchNormalized
            let extra = all.filter { track in
                !track.artists.contains { $0.id == browseId }
                    && track.artistLine.matches(normalizedQuery: normalizedName)
            }
            mine.append(contentsOf: extra)
        }
        libraryTracks = mine
        scanningLibrary = false
    }
}
