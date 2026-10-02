import SwiftUI
import EncoreCore

// MARK: - Artist

struct ArtistScreen: View {
    let browseId: String
    @EnvironmentObject var player: PlayerEngine
    @State private var page: ArtistPage?
    @State private var libraryTracks: [Track] = []
    @State private var libraryExpanded = false
    @State private var artistSummary: String?
    @State private var loading = true
    /// Release shelves ("Albums", "Singles & EPs") the user has expanded.
    @State private var expandedReleases: Set<String> = []

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
                        Text(page.name).font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 16)
                    }
                    if let artistSummary {
                        // Wikidata bio: birthplace · age · country · career start
                        // (+ members for bands).
                        Text(artistSummary)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 22)
                    }
                    if !libraryTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("In your playlists & likes").font(.system(size: 18, weight: .bold))
                                Text("\(libraryTracks.count) song\(libraryTracks.count == 1 ? "" : "s") from your collection")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 22)
                            let shown = libraryExpanded ? libraryTracks : Array(libraryTracks.prefix(8))
                            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                                TrackRowView(track: t, onRemoveFromPlaylist: nil) {
                                    player.playCollection(libraryTracks, startAt: i)
                                }.padding(.horizontal, 22)
                            }
                            if libraryTracks.count > 8 {
                                Button {
                                    withAnimation { libraryExpanded.toggle() }
                                } label: {
                                    Text(libraryExpanded ? "Show less" : "Show all \(libraryTracks.count) songs")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                                .padding(.horizontal, 22)
                                .padding(.top, 2)
                            }
                        }
                    }
                    ForEach(ArtistMatch.visibleShelves(page.shelves)) { shelf in
                        if shelf.isReleaseShelf {
                            releaseList(shelf)
                        } else {
                            ShelfRow(shelf: shelf)
                        }
                    }
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

    /// Albums / Singles & EPs as a vertical list, like the songs (Charlie,
    /// 2026-10-01) — the full discography is 30+ releases, too many to flick
    /// through sideways. The first few show; "Show all" expands in place.
    private func releaseList(_ shelf: Shelf) -> some View {
        let cards = shelf.items.compactMap { item -> CardItem? in
            if case .card(let c) = item { return c }
            return nil
        }
        let expanded = expandedReleases.contains(shelf.title)
        let shown = expanded ? cards : Array(cards.prefix(Shelf.releasePreviewCount))
        return VStack(alignment: .leading, spacing: 8) {
            Text(shelf.title).font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(shown) { CardListRow(item: $0) }
            }
            .padding(.horizontal, 16)
            if cards.count > Shelf.releasePreviewCount {
                Button {
                    withAnimation {
                        if expanded { expandedReleases.remove(shelf.title) }
                        else { expandedReleases.insert(shelf.title) }
                    }
                } label: {
                    Text(expanded ? "Show less" : "Show all \(cards.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
            }
        }
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
