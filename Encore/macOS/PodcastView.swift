import SwiftUI
import EncoreCore

/// Apple-Podcasts-style show page (macOS) — parity with the iOS PodcastScreen.
/// Big header, expandable description, Recent/Oldest sort, and episode rows with
/// date, notes, duration, a play button, and a mark-as-played toggle.
struct PodcastView: View {
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
        Group {
            if let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(page)
                            .padding(.horizontal, 28).padding(.top, 28)

                        HStack {
                            Text("Episodes").font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            sortMenu
                        }
                        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 6)

                        // One decode of the progress map per render, not per row.
                        let progressMap = EpisodeProgress.all()
                        LazyVStack(spacing: 0) {
                            ForEach(Array(episodes.enumerated()), id: \.offset) { i, ep in
                                MacEpisodeRow(episode: ep,
                                              isCurrent: player.current?.videoId == ep.videoId,
                                              isPlayed: playedIds.contains(ep.videoId),
                                              progress: progressMap[ep.videoId],
                                              onTogglePlayed: { togglePlayed(ep) }) {
                                    player.playCollection(episodes, startAt: i)
                                }
                                Divider().background(Theme.stroke).padding(.leading, 28)
                            }
                        }
                        .padding(.bottom, 36)
                    }
                }
            } else if loading {
                LoadingView()
            }
        }
        .background(Theme.bg)
        .task {
            newestFirst = UserDefaults.standard.object(forKey: sortKey) as? Bool ?? true
            playedIds = PlayedEpisodes.all()
            await load()
        }
        .onChange(of: newestFirst) { _, v in UserDefaults.standard.set(v, forKey: sortKey) }
    }

    private var sortMenu: some View {
        Menu {
            Button { newestFirst = true } label: {
                if newestFirst { Label("Recent", systemImage: "checkmark") } else { Text("Recent") }
            }
            Button { newestFirst = false } label: {
                if !newestFirst { Label("Oldest", systemImage: "checkmark") } else { Text("Oldest") }
            }
        } label: {
            HStack(spacing: 5) {
                Text(newestFirst ? "Recent" : "Oldest").font(.system(size: 12, weight: .medium))
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
            }.foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func header(_ page: CollectionPage) -> some View {
        HStack(alignment: .top, spacing: 22) {
            ArtworkView(url: Artwork.upscale(page.thumbnailURL, to: 400), corner: 12)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)

            VStack(alignment: .leading, spacing: 10) {
                Text("PODCAST").font(.system(size: 11, weight: .bold)).kerning(1)
                    .foregroundStyle(Theme.textSecondary)
                Text(page.title).font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary).lineLimit(3)
                if !page.subtitle.isEmpty {
                    Text(page.subtitle).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.fallbackAccent).lineLimit(1)
                }
                HStack(spacing: 10) {
                    PillButton(title: "Play", icon: "play.fill", prominent: true) {
                        player.playCollection(episodes, startAt: 0)
                    }
                    PillButton(title: "Shuffle", icon: "shuffle") {
                        player.playShuffled(episodes)
                    }
                }
                .padding(.top, 2)
                if let desc = page.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(desc).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(descExpanded ? nil : 4)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(descExpanded ? "less" : "more") { descExpanded.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.fallbackAccent)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func togglePlayed(_ episode: Track) {
        PlayedEpisodes.toggle(episode.videoId)
        playedIds = PlayedEpisodes.all()
        // Marking played discards the resume point (Apple Podcasts behavior).
        if playedIds.contains(episode.videoId) { EpisodeProgress.clear(episode.videoId) }
    }

    private func load() async {
        if let cached = PageCache.shared.collections[cacheKey] { page = cached; loading = false }
        if let fresh = try? await YTM.shared.podcastShow(browseId: browseId) {
            page = fresh; PageCache.shared.collections[cacheKey] = fresh
        }
        loading = false
    }
}

private struct MacEpisodeRow: View {
    @EnvironmentObject var player: PlayerEngine
    let episode: Track
    let isCurrent: Bool
    let isPlayed: Bool
    /// Saved playback position, when the episode was left partway through.
    var progress: EpisodeProgressEntry? = nil
    let onTogglePlayed: () -> Void
    let onPlay: () -> Void

    @State private var hovering = false

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
        if isCurrent { return Theme.fallbackAccent }
        return isPlayed ? Theme.textTertiary : Theme.textPrimary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if isPlayed {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Theme.fallbackAccent)
                }
                if let date = episode.dateText, !date.isEmpty {
                    Text((isPlayed ? "PLAYED · " : "") + date.uppercased())
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                } else if isPlayed {
                    Text("PLAYED").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
            Text(episode.title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(titleColor).lineLimit(2)
            if let details = episode.details, !details.isEmpty {
                Text(details).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button(action: onPlay) {
                    HStack(spacing: 7) {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 26))
                        if let frac = progressFraction {
                            // Partially played: a small bar + time left, like
                            // Apple Podcasts. Resumes from this spot on play.
                            ProgressView(value: frac)
                                .progressViewStyle(.linear)
                                .tint(Theme.fallbackAccent)
                                .frame(width: 70)
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
                        .font(.system(size: 16))
                        .foregroundStyle(isPlayed ? Theme.fallbackAccent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(isPlayed ? "Mark as Unplayed" : "Mark as Played")
                Menu {
                    Button("Play") { onPlay() }
                    Button("Play Next") { player.playNext(episode) }
                    Button("Add to Queue") { player.addToQueue(episode) }
                    Button(isPlayed ? "Mark as Unplayed" : "Mark as Played") { onTogglePlayed() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 28).padding(.vertical, 13)
        .background(hovering ? Theme.card : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
