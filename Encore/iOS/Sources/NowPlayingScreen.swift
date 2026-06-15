import SwiftUI
import EncoreCore

struct NowPlayingScreen: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    // NOTE: do NOT observe PlayerClock here — the time tick (4 Hz) would
    // re-render the whole screen incl. the blurred backdrop. ProgressBar and
    // LyricsPane observe the clock themselves.
    @Environment(\.dismiss) private var dismiss

    enum Tab { case song, lyrics, queue }
    @State private var tab: Tab = .song

    /// Square artwork sized so it never makes the layout wider than the screen.
    private var artSize: CGFloat {
        let b = UIScreen.main.bounds
        return min(b.width - 72, b.height * 0.40)
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 16) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 5).padding(.top, 8)

                Picker("", selection: $tab) {
                    Text("Song").tag(Tab.song)
                    Text("Lyrics").tag(Tab.lyrics)
                    Text("Queue").tag(Tab.queue)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)

                switch tab {
                case .song: songPane
                case .lyrics: LyricsPane()
                case .queue: QueuePane()
                }
            }
            .padding(.top, 32) // clear the Dynamic Island
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .preferredColorScheme(.dark)
        .gesture(DragGesture().onEnded { v in if v.translation.height > 90 { dismiss() } })
    }

    private var backdrop: some View {
        ZStack {
            Theme.bg
            // A .fill image with no fixed frame inflates the layout width and
            // pushes the rest of the screen off-center; pin it to the screen.
            AsyncImage(url: player.current?.artworkURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill).blur(radius: 60).opacity(0.5)
                }
            }
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            .clipped()
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var songPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ArtworkView(url: player.current?.artworkURL, corner: 16)
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .scaleEffect(player.isPlaying ? 1 : 0.95)
                .animation(.spring(duration: 0.4), value: player.isPlaying)
            Spacer(minLength: 0)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.title ?? "").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(player.current?.artistLine ?? "").font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .onTapGesture {
                            if let a = player.current?.artists.first {
                                dismiss(); nav.goArtist(id: a.id, name: a.name)
                            }
                        }
                }
                Spacer()
                Button { if let t = player.current { player.toggleLike(t) } } label: {
                    Image(systemName: player.current.map { player.likedIds.contains($0.videoId) } == true
                          ? "heart.fill" : "heart")
                        .font(.system(size: 22))
                        .foregroundStyle(player.current.map { player.likedIds.contains($0.videoId) } == true
                                         ? Theme.accent : .white.opacity(0.7))
                }
            }
            .padding(.horizontal, 36)

            ProgressBar().padding(.horizontal, 36).padding(.top, 18)

            if player.current?.isEpisode == true {
                HStack(spacing: 22) {
                    speedButton
                    ctrl("gobackward.15", size: 28) { player.skip(-15) }
                    bigPlayButton
                    ctrl("goforward.30", size: 28) { player.skip(30) }
                    sleepMenu
                }
                .padding(.top, 22)
                Button { player.showNowPlaying = false } label: {
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 18)
            } else {
                HStack(spacing: 28) {
                    ctrl("shuffle", active: player.shuffleOn, size: 18) { player.toggleShuffle() }
                    ctrl("backward.fill", size: 26) { player.previous() }
                    bigPlayButton
                    ctrl("forward.fill", size: 26) { player.next() }
                    ctrl(player.repeatMode == .one ? "repeat.1" : "repeat",
                         active: player.repeatMode != .off, size: 18) { player.cycleRepeat() }
                }
                .padding(.top, 22)

                HStack(spacing: 36) {
                    sleepMenu
                    Button { player.showNowPlaying = false } label: {
                        Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.top, 18)
            }
            Spacer(minLength: 0)
        }
    }

    private var bigPlayButton: some View {
        Button { player.togglePlay() } label: {
            ZStack {
                Circle().fill(.white).frame(width: 70, height: 70)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(.black)
                    .offset(x: player.isPlaying ? 0 : 2)
            }
        }
    }

    private func rateLabel(_ r: Double) -> String {
        let s = r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
        return "\(s)×"
    }

    private var speedButton: some View {
        Menu {
            ForEach([0.8, 1.0, 1.2, 1.5, 1.75, 2.0], id: \.self) { r in
                Button { player.setPlaybackRate(r) } label: {
                    if player.playbackRate == r { Label(rateLabel(r), systemImage: "checkmark") }
                    else { Text(rateLabel(r)) }
                }
            }
        } label: {
            Text(rateLabel(player.playbackRate))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(player.playbackRate != 1.0 ? Theme.accent : .white)
                .frame(minWidth: 40)
        }
    }

    private var sleepMenu: some View {
        Menu {
            if player.sleepTimer.isActive { Button("Turn Off Timer") { player.cancelSleepTimer() } ; Divider() }
            Section("Stop after time") {
                ForEach([15, 30, 45, 60], id: \.self) { m in Button("\(m) min") { player.setSleepTimer(minutes: m) } }
            }
            Section("Stop after songs") {
                ForEach(1...5, id: \.self) { n in Button(n == 1 ? "1 song" : "\(n) songs") { player.setSleepTimer(songs: n) } }
            }
        } label: {
            Image(systemName: player.sleepTimer.isActive ? "moon.fill" : "moon")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(player.sleepTimer.isActive ? Theme.accent : .white.opacity(0.6))
        }
    }

    private func ctrl(_ icon: String, active: Bool = false, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : .white)
        }
    }
}

struct ProgressBar: View {
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var clock = PlayerClock.shared
    @State private var dragFraction: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let shown = dragFraction ?? clock.progress
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 5)
                    Capsule().fill(.white).frame(width: max(0, w * shown), height: 5)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = max(0, min($0.location.x / w, 1)) }
                    .onEnded { v in player.seek(fraction: max(0, min(v.location.x / w, 1))); dragFraction = nil })
            }
            .frame(height: 14)
            HStack {
                Text(Track.format(seconds: Int(clock.currentTime)))
                Spacer()
                Text(Track.format(seconds: Int(clock.duration)))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

struct LyricsPane: View {
    @ObservedObject private var clock = PlayerClock.shared
    @EnvironmentObject var player: PlayerEngine
    @AppStorage("lyricsProvider") private var providerChoice = "auto"

    var body: some View {
        VStack(spacing: 0) {
            content
            Menu {
                ForEach(LyricsService.Provider.allCases, id: \.rawValue) { p in
                    Button {
                        providerChoice = p.rawValue
                        LyricsService.shared.preferred = p
                        player.refetchLyrics()
                    } label: {
                        if providerChoice == p.rawValue { Label(p.displayName, systemImage: "checkmark") }
                        else { Text(p.displayName) }
                    }
                }
            } label: {
                Text(clock.lyrics?.source.displayName ?? "Auto")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if clock.lyricsLoading {
            Spacer(); ProgressView().tint(.white); Spacer()
        } else if let lines = clock.lyrics?.lines, !lines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 40)
                        ForEach(lines) { line in
                            let active = clock.currentLyricIndex == line.id
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: active ? 22 : 18, weight: active ? .bold : .semibold))
                                .foregroundStyle(active ? Theme.accent : .white.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                                .onTapGesture { player.seek(to: Double(line.startMs) / 1000) }
                        }
                        Color.clear.frame(height: 60)
                    }
                    .padding(.horizontal, 28)
                }
                .onChange(of: clock.currentLyricIndex) { _, idx in
                    if let idx { withAnimation(.spring) { proxy.scrollTo(idx, anchor: .center) } }
                }
            }
        } else if let plain = clock.lyrics?.plain {
            ScrollView(showsIndicators: false) {
                Text(plain).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75)).lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }
        } else {
            Spacer()
            Text("No lyrics for this track").font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
    }
}

struct QueuePane: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Up Next").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "infinity").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(player.autoplayEnabled ? Theme.accent : .white.opacity(0.3))
                Toggle("", isOn: $player.autoplayEnabled).labelsHidden().tint(Theme.accent)
                    .scaleEffect(0.8)
            }
            .padding(.horizontal, 24).padding(.bottom, 6)
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { i, track in
                        HStack(spacing: 11) {
                            ArtworkView(url: track.thumbnailURL, corner: 4).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.system(size: 14, weight: i == player.index ? .semibold : .regular))
                                    .foregroundStyle(i == player.index ? Theme.accent : .white).lineLimit(1)
                                Text(track.artistLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture { player.jump(to: i) }
                        .id(i)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear { proxy.scrollTo(player.index, anchor: .top) }
            }
        }
    }
}
