import SwiftUI
import EncoreCore

/// Your songs ranked by personal play count (tracked locally — see PlayCounts).
struct MostPlayedView: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var records: [PlayRecord] = []

    private var tracks: [Track] { records.map(\.track) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Most Played")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if tracks.count > 1 {
                        Button { player.playCollection(tracks, startAt: 0) } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button { player.playShuffled(tracks) } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)

                if records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 40)).foregroundStyle(Theme.textTertiary)
                        Text("No plays yet")
                            .font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                        Text("Songs you play are ranked here by how many times you've listened.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.offset) { i, rec in
                            MostPlayedRow(rank: i + 1, record: rec,
                                          isCurrent: player.current?.videoId == rec.track.videoId) {
                                player.playCollection(tracks, startAt: i)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 36)
        }
        .task { records = PlayCounts.mostPlayed() }
    }
}

private struct MostPlayedRow: View {
    let rank: Int
    let record: PlayRecord
    let isCurrent: Bool
    let onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, alignment: .trailing)
            RemoteImage(url: record.track.thumbnailURL)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(NativeNames.displayTitle(for: record.track))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isCurrent ? Theme.fallbackAccent : Theme.textPrimary)
                    .lineLimit(1)
                Text(record.track.artistLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(record.count) play\(record.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onPlay() }
    }
}
