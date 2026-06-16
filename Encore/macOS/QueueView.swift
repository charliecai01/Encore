import SwiftUI
import EncoreCore

struct QueuePanel: View {
    @EnvironmentObject var player: PlayerEngine
    @Binding var shown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Up Next")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                AutoplayToggle()
                Button {
                    shown = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.card, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 46)
            .padding(.bottom, 10)

            QueueList()
                .padding(.horizontal, 6)
        }
        .background(Theme.bgElevated)
    }
}

/// YT Music's "Autoplay" switch: keep playing similar music when the queue ends.
struct AutoplayToggle: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "infinity")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(player.autoplayEnabled ? Theme.fallbackAccent : Theme.textTertiary)
            Toggle("", isOn: $player.autoplayEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .help("Autoplay — keep playing similar music when the queue ends")
    }
}

struct QueueList: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        if player.queue.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textTertiary)
                Text("Queue is empty")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { i, track in
                        QueueRow(track: track,
                                 isCurrent: i == player.index,
                                 position: i) {
                            player.jump(to: i)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .id(i)
                    }
                    .onMove { from, to in player.moveQueue(from: from, to: to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    proxy.scrollTo(player.index, anchor: .center)
                }
                .clipped()
            }
        }
    }
}

struct QueueRow: View {
    @EnvironmentObject var player: PlayerEngine

    let track: Track
    let isCurrent: Bool
    let position: Int
    let onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                ArtworkView(url: track.thumbnailURL, corner: 5)
                    .frame(width: 38, height: 38)
                if isCurrent && player.isPlaying {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.black.opacity(0.45))
                        .frame(width: 38, height: 38)
                    NowPlayingBars()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? Theme.fallbackAccent : Theme.textPrimary)
                    .lineLimit(1)
                Text(track.artistLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if hovering && !isCurrent {
                Button {
                    player.removeFromQueue(at: position)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            } else {
                Text(track.durationText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .hoverHighlight(hovering)
        .onHover { hovering = $0 }
        .onTapGesture { onPlay() }
    }
}
