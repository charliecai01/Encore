import SwiftUI
import EncoreCore

/// Chooses which full-screen player to present: podcasts get their own
/// Apple-Podcasts-style screen, songs keep the music screen. Splitting them at
/// the presentation level (instead of branching inside one screen) is what
/// prevents the old bug where the two UIs mixed and the podcast speed control
/// could act on a song.
struct NowPlayingSwitcher: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        if PodcastFeature.enabled, player.current?.isEpisode == true {
            PodcastNowPlayingScreen()
        } else {
            NowPlayingScreen()
        }
    }
}

/// Apple-Podcasts-style now playing: artwork (or the episode's video), release
/// date, episode title + show, scrubber, ±15/30s transport, speed, sleep,
/// AirPlay, and mark-as-played.
struct PodcastNowPlayingScreen: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var dragOffset: CGFloat = 0
    @State private var played = false
    @State private var showVideo = false

    private var episode: Track? { player.current }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .gesture(dismissDrag)

            Spacer(minLength: 8)

            ArtworkView(url: Artwork.upscale(episode?.artworkURL, to: 720), corner: 12)
                .frame(width: 300, height: 300)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                .gesture(dismissDrag)
                .padding(.horizontal, 24)

            Spacer(minLength: 14)

            VStack(alignment: .leading, spacing: 5) {
                if let date = episode?.dateText, !date.isEmpty {
                    Text(date.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text(episode?.title ?? "")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let show = episode?.artistLine, !show.isEmpty {
                    Text(show)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)

            ProgressBar().padding(.horizontal, 36).padding(.top, 16)

            // Transport: speed · back 15 · play/pause · forward 30 · sleep.
            HStack(spacing: 22) {
                speedButton
                ctrl("gobackward.15", size: 30) { player.skip(-15) }
                playButton
                ctrl("goforward.30", size: 30) { player.skip(30) }
                sleepMenu
            }
            .padding(.top, 20)

            // Secondary: mark played · video · AirPlay · more · dismiss.
            HStack(spacing: 34) {
                Button {
                    togglePlayed()
                } label: {
                    Image(systemName: played ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(played ? Theme.accent : .white.opacity(0.6))
                }
                if PodcastFeature.videoEnabled {
                    Button {
                        showVideo = true
                    } label: {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                RoutePickerButton().frame(width: 26, height: 26)
                Menu {
                    Button(played ? "Mark as Unplayed" : "Mark as Played") { togglePlayed() }
                    if let url = episode?.shareURL {
                        ShareLink(item: url) { Label("Share Episode", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.url = url } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                Button { player.showNowPlaying = false } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.top, 18)

            Spacer(minLength: 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(backdrop)
        .preferredColorScheme(.dark)
        // Toasts render on MobileRoot, hidden under this cover — mirror them.
        .overlay(alignment: .top) {
            if let toast = player.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.toast)
        .offset(y: dragOffset)
        .fullScreenCover(isPresented: $showVideo) {
            PodcastVideoScreen().environmentObject(player)
        }
        .onAppear { syncPlayed() }
        .onChange(of: player.current?.videoId) { _, _ in syncPlayed() }
        .onDisappear { player.videoMode = false }
    }

    private func syncPlayed() {
        played = episode.map { PlayedEpisodes.isPlayed($0.videoId) } ?? false
    }

    private func togglePlayed() {
        guard let ep = episode else { return }
        PlayedEpisodes.toggle(ep.videoId)
        played = PlayedEpisodes.isPlayed(ep.videoId)
        if played { EpisodeProgress.clear(ep.videoId) }
    }

    private var playButton: some View {
        Button { player.togglePlay() } label: {
            ZStack {
                Circle().fill(.white).frame(width: 70, height: 70)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(.black)
                    .offset(x: player.isPlaying ? 0 : 2)
            }
        }
    }

    private func ctrl(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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
                // Fixed width so a rate change doesn't shove the play button.
                .frame(width: 52)
        }
    }

    private var sleepMenu: some View {
        Menu {
            if player.sleepTimer.isActive { Button("Turn Off Timer") { player.cancelSleepTimer() }; Divider() }
            Section("Stop after time") {
                ForEach([15, 30, 45, 60], id: \.self) { m in Button("\(m) min") { player.setSleepTimer(minutes: m) } }
            }
        } label: {
            Image(systemName: player.sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(player.sleepTimer.isActive ? Theme.accent : .white.opacity(0.8))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var backdrop: some View {
        ZStack {
            Theme.bg
            AsyncImage(url: episode?.artworkURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill).blur(radius: 60).opacity(0.45)
                }
            }
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            .clipped()
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { v in if v.translation.height > 0 { dragOffset = v.translation.height } }
            .onEnded { v in
                if v.translation.height > 160 || v.predictedEndTranslation.height > 300 {
                    player.showNowPlaying = false
                }
                withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
            }
    }
}

/// Full-screen video for the current episode. Opens PORTRAIT (video
/// letterboxed on black); a rotate button flips the app to landscape and back
/// — the rest of the app stays portrait-only. Tap anywhere to show/hide the
/// controls.
struct PodcastVideoScreen: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var landscape = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PodcastVideoHost().ignoresSafeArea()
            if showControls { controls }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showControls.toggle() } }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            player.videoMode = true
        }
        .onDisappear {
            player.videoMode = false
            OrientationLock.set(.portrait)
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.45), in: Circle())
                }
                Spacer()
                Button {
                    landscape.toggle()
                    OrientationLock.set(landscape ? .landscape : .portrait)
                } label: {
                    Image(systemName: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            Spacer()
            HStack(spacing: 48) {
                videoCtrl("gobackward.15") { player.skip(-15) }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.black.opacity(0.45), in: Circle())
                }
                videoCtrl("goforward.30") { player.skip(30) }
            }
            ProgressBar()
                .padding(.horizontal, 24)
                .padding(.top, 10)
        }
        .padding(20)
        .transition(.opacity)
    }

    private func videoCtrl(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.45), in: Circle())
        }
    }
}

/// Hosts the shared player web view while the podcast screen shows video.
/// Borrows the WKWebView from its hidden 1×1 park in MobileRoot and returns it
/// on teardown — the view must never be detached long or WebKit throttles it.
struct PodcastVideoHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.clipsToBounds = true
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        let web = PlayerEngine.shared.webView
        if web.superview !== v {
            web.removeFromSuperview()
            v.addSubview(web)
        }
        web.frame = v.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        Task { @MainActor in PlayerEngine.shared.parkWebView() }
    }
}
