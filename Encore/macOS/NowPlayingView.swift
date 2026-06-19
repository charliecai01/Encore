import SwiftUI
import AppKit
import EncoreCore

/// Full-window immersive player: blurred artwork backdrop, big controls,
/// karaoke-style synced lyrics, and an optional video mode that surfaces the
/// underlying YouTube player.
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @Binding var expanded: Bool

    enum Pane: String, CaseIterable {
        case lyrics = "Lyrics"
        case queue = "Up Next"
    }

    @State private var pane: Pane = .lyrics
    @State private var palette = Palette.fallback

    // Directional slide of the big artwork as the track changes (mirrors the
    // official app). `shownTrack` lags `player.current` by one render so the
    // swap runs inside an animated transaction; direction = index delta.
    @State private var shownTrack: Track?
    @State private var slideForward = true
    @State private var lastIndex = 0

    var body: some View {
        // Hard-clamp to the window: if any pane's ideal width exceeds it,
        // SwiftUI would otherwise center the overflow and clip both edges.
        GeometryReader { geo in
            ZStack {
                backdrop(geo.size)

                VStack(spacing: 0) {
                // ZStack keeps the picker dead-center and the buttons pinned
                // to the edges at any window size.
                ZStack {
                    Picker("", selection: $pane) {
                        ForEach(Pane.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    HStack {
                        Button {
                            expanded = false
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Back")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .help("Close (Esc)")

                        Spacer()

                        Button {
                            player.copyCurrentLink()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.12), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .disabled(player.current == nil)
                        .help("Copy link to song")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                // Stay above the panes: ScrollViews on macOS can draw outside
                // their bounds and would otherwise paint over this bar.
                .zIndex(1)

                    HStack(spacing: 40) {
                        leftColumn
                            .frame(maxWidth: .infinity)

                        Group {
                            switch pane {
                            case .lyrics:
                                LyricsPane(accent: palette.accent)
                            case .queue:
                                VStack(spacing: 6) {
                                    HStack {
                                        Spacer()
                                        Text("Autoplay")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.6))
                                        AutoplayToggle()
                                    }
                                    QueueList()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 24)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onExitCommand { expanded = false }
        .task(id: player.current?.videoId) {
            palette = await ArtworkPalette.shared.palette(for: player.current?.thumbnailURL)
        }
        .onDisappear {
            PlayerEngine.shared.park()
        }
    }

    private func backdrop(_ size: CGSize) -> some View {
        ZStack {
            Theme.bg
            // A .fill image with no fixed frame inflates the layout and shifts
            // the controls off-screen on resize; pin it to the window size.
            AsyncImage(url: player.current?.artworkURL) { phase in
                if case .success(let image) = phase {
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 70)
                        .saturation(1.4)
                        .opacity(0.55)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture { expanded = false }
    }

    private var leftColumn: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            ZStack {
                ArtworkView(url: shownTrack?.artworkURL, corner: 14)
                    .id(shownTrack?.videoId)
                    .transition(.asymmetric(
                        insertion: .move(edge: slideForward ? .trailing : .leading),
                        removal:   .move(edge: slideForward ? .leading  : .trailing)
                    ))
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 360, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 36, y: 14)
            .scaleEffect(player.isPlaying ? 1 : 0.94)
            .animation(.spring(duration: 0.45), value: player.isPlaying)
            .onAppear { shownTrack = player.current; lastIndex = player.index }
            .onChange(of: player.current?.videoId) { _, _ in
                slideForward = player.index >= lastIndex
                lastIndex = player.index
                withAnimation(.easeInOut(duration: 0.34)) { shownTrack = player.current }
            }

            VStack(spacing: 5) {
                Text(player.current?.title ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(player.current?.artistLine ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: 460)

            VStack(spacing: 10) {
                NowPlayingSeekRow(accent: palette.accent)
                    .frame(maxWidth: 440)

                HStack(spacing: 30) {
                    ControlButton(icon: "shuffle", size: 15, active: player.shuffleOn) {
                        player.toggleShuffle()
                    }
                    ControlButton(icon: "backward.fill", size: 22) {
                        player.previous()
                    }
                    Button {
                        player.togglePlay()
                    } label: {
                        ZStack {
                            Circle().fill(.white)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: player.isPlaying ? 0 : 2)
                        }
                        .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.plain)
                    ControlButton(icon: "forward.fill", size: 22) {
                        player.next()
                    }
                    ControlButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                                  size: 15, active: player.repeatMode != .off) {
                        player.cycleRepeat()
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

/// Time labels + scrubber, isolated so the 4 Hz clock tick only re-renders this
/// row — not the parent's full-window blurred backdrop (which was the lag).
private struct NowPlayingSeekRow: View {
    let accent: Color
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var clock = PlayerClock.shared

    var body: some View {
        HStack(spacing: 9) {
            Text(Track.format(seconds: Int(clock.currentTime)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            SeekBar(progress: clock.progress, accent: accent) { fraction in
                player.seek(fraction: fraction)
            }
            Text(Track.format(seconds: Int(clock.duration)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// Karaoke-style synced lyrics (QQ Music / NetEase style): active line lights
/// up and the list auto-centers on it; tap a line to seek.
struct LyricsPane: View {
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var clock = PlayerClock.shared
    let accent: Color

    var body: some View {
        Group {
            if clock.lyricsLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lines = clock.lyrics?.lines, !lines.isEmpty {
                syncedLyrics(lines)
            } else if let plain = clock.lyrics?.plain {
                ScrollView(showsIndicators: false) {
                    Text(plain)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineSpacing(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 40)
                }
                .clipped()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("No lyrics for this track")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            providerMenu
        }
    }

    @AppStorage("lyricsProvider") private var providerChoice = "auto"

    private var providerMenu: some View {
        Menu {
            Text("Lyrics source")
            ForEach(LyricsService.Provider.allCases, id: \.rawValue) { provider in
                Button {
                    providerChoice = provider.rawValue
                    LyricsService.shared.preferred = provider
                    player.refetchLyrics()
                } label: {
                    if providerChoice == provider.rawValue {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(clock.lyrics?.source.displayName
                     ?? LyricsService.Provider(rawValue: providerChoice)?.displayName
                     ?? "Auto")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(8)
        .help("Choose lyrics provider")
    }

    private func syncedLyrics(_ lines: [LyricLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    Spacer().frame(height: 160)
                    ForEach(lines) { line in
                        let isActive = clock.currentLyricIndex == line.id
                        let isPast = (clock.currentLyricIndex ?? -1) > line.id
                        Button {
                            player.seek(to: Double(line.startMs) / 1000)
                        } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: isActive ? 24 : 20,
                                              weight: isActive ? .bold : .semibold))
                                .foregroundStyle(
                                    isActive ? accent : .white.opacity(isPast ? 0.3 : 0.55)
                                )
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .animation(.easeOut(duration: 0.2), value: isActive)
                    }
                    Spacer().frame(height: 200)
                }
            }
            .onChange(of: clock.currentLyricIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.spring(duration: 0.5)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .clipped()
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Hosts the shared playback web view full-size for video mode.
struct VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = PlayerEngine.shared.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = PlayerEngine.shared.webView
        if webView.superview != nsView {
            webView.removeFromSuperview()
            webView.frame = nsView.bounds
            webView.autoresizingMask = [.width, .height]
            nsView.addSubview(webView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        Task { @MainActor in
            PlayerEngine.shared.park()
        }
    }
}
