import SwiftUI
import AppKit
import AVKit
import EncoreCore

struct PlayerBar: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    @ObservedObject private var clock = PlayerClock.shared
    @Binding var nowPlayingExpanded: Bool
    @Binding var queueShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 16) {
                trackInfo
                    .frame(width: 280, alignment: .leading)

                transport
                    .frame(maxWidth: .infinity)

                rightControls
                    .frame(width: 250, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 86)
            .background(Theme.bgElevated)
        }
    }

    private var trackInfo: some View {
        HStack(spacing: 11) {
            if let track = player.current {
                Button {
                    nowPlayingExpanded = true
                } label: {
                    ZStack {
                        ArtworkView(url: track.thumbnailURL, corner: 6)
                            .frame(width: 56, height: 56)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(0)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .onTapGesture {
                            if let albumId = track.album?.id { nav.go(.album(albumId)) }
                        }
                    Text(track.artistLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .onTapGesture {
                            if let artist = track.artists.first {
                                nav.goArtist(id: artist.id, name: artist.name)
                            }
                        }
                }

                Button {
                    player.toggleLike(track)
                } label: {
                    Image(systemName: player.likedIds.contains(track.videoId) ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(player.likedIds.contains(track.videoId)
                                         ? Theme.fallbackAccent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.card)
                    .frame(width: 56, height: 56)
                Text("Nothing playing")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var transport: some View {
        VStack(spacing: 7) {
            HStack(spacing: 22) {
                ControlButton(icon: "shuffle", size: 13,
                              active: player.shuffleOn) {
                    player.toggleShuffle()
                }
                ControlButton(icon: "backward.fill", size: 16) {
                    player.previous()
                }
                Button {
                    player.togglePlay()
                } label: {
                    ZStack {
                        Circle().fill(.white)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(player.current == nil)
                ControlButton(icon: "forward.fill", size: 16) {
                    player.next()
                }
                ControlButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat", size: 13,
                              active: player.repeatMode != .off) {
                    player.cycleRepeat()
                }
            }

            HStack(spacing: 9) {
                Text(Track.format(seconds: Int(clock.currentTime)))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 40, alignment: .trailing)
                SeekBar(progress: clock.progress, accent: .white) { fraction in
                    player.seek(fraction: fraction)
                }
                .frame(maxWidth: 480)
                Text(Track.format(seconds: Int(clock.duration)))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 40, alignment: .leading)
            }
        }
    }

    private var rightControls: some View {
        HStack(spacing: 14) {
            ControlButton(icon: "square.and.arrow.up", size: 14) {
                player.copyCurrentLink()
            }
            .disabled(player.current == nil)
            .help("Copy link to song")
            sleepTimerMenu
            ControlButton(icon: "quote.bubble", size: 14,
                          active: nowPlayingExpanded) {
                nowPlayingExpanded.toggle()
            }
            ControlButton(icon: "list.bullet", size: 14, active: queueShown) {
                queueShown.toggle()
            }
            RoutePickerButton()
                .frame(width: 20, height: 16)
                .help("AirPlay / output device")
            HStack(spacing: 7) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                SeekBar(progress: player.volume, accent: .white) { fraction in
                    player.volume = fraction
                }
                .frame(width: 84)
            }
            ControlButton(icon: "chevron.up", size: 13) {
                nowPlayingExpanded = true
            }
        }
    }

    private var sleepTimerMenu: some View {
        Menu {
            if case .time(let end) = player.sleepTimer {
                Text("Stopping in \(max(0, Int(end.timeIntervalSinceNow / 60)) + 1) min")
            }
            if case .songs(let n) = player.sleepTimer {
                Text(n == 1 ? "Stopping after this song" : "Stopping after \(n) songs")
            }
            if player.sleepTimer.isActive {
                Button("Turn Off Timer") { player.cancelSleepTimer() }
                Divider()
            }
            Section("Stop after time") {
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                }
            }
            Section("Stop after songs") {
                ForEach(1...5, id: \.self) { count in
                    Button(count == 1 ? "1 song" : "\(count) songs") {
                        player.setSleepTimer(songs: count)
                    }
                }
            }
        } label: {
            Image(systemName: player.sleepTimer.isActive ? "moon.fill" : "moon")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(player.sleepTimer.isActive ? Theme.fallbackAccent : Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sleep timer")
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: return "speaker.slash.fill"
        case ..<0.4: return "speaker.wave.1.fill"
        case ..<0.75: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

struct ControlButton: View {
    let icon: String
    var size: CGFloat = 14
    var active = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Theme.fallbackAccent
                                 : (hovering ? Theme.textPrimary : Theme.textSecondary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Native output-route picker (AirPlay). Routes the app's audio output; the
/// hidden web player's audio follows the selected device.
struct RoutePickerButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(NSColor(Theme.textSecondary), for: .normal)
        picker.setRoutePickerButtonColor(NSColor(Theme.fallbackAccent), for: .active)
        return picker
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// Custom slider used for seek and volume — thin capsule that grows a knob on hover.
struct SeekBar: View {
    let progress: Double
    var accent: Color = .white
    let onSeek: (Double) -> Void

    @State private var hovering = false
    @State private var dragFraction: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = dragFraction ?? progress
            let fillWidth = max(0, min(shown, 1)) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 4)
                Capsule()
                    .fill(hovering || dragFraction != nil ? accent : Color.white.opacity(0.72))
                    .frame(width: fillWidth, height: 4)
                if hovering || dragFraction != nil {
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: fillWidth - 5.5)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = max(0, min(value.location.x / width, 1))
                    }
                    .onEnded { value in
                        let fraction = max(0, min(value.location.x / width, 1))
                        onSeek(fraction)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
    }
}
