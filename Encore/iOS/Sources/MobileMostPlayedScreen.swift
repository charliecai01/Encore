import SwiftUI
import EncoreCore

// MARK: - Most Played

/// The ranked play-count list. Shared by the Library ▸ Most Played tab and
/// the standalone screen, so the two can't drift.
struct MostPlayedList: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var records: [PlayRecord] = []

    private var tracks: [Track] { records.map(\.track) }

    var body: some View {
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
                                    Text(NativeNames.displayTitle(rec.track.title)).font(.system(size: 15, weight: .medium))
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
            }
            .task { records = PlayCounts.mostPlayed() }
    }
}

struct MostPlayedScreen: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                MostPlayedList()
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Most Played").navigationBarTitleDisplayMode(.inline)
    }
}
