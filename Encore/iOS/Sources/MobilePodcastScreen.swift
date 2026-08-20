import SwiftUI
import EncoreCore

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
