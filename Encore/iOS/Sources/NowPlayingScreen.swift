import SwiftUI
import AVKit
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

    // Drives the directional slide of the big artwork as the track changes.
    // `shownTrack` lags `player.current` by one render so the swap happens
    // inside an animated transaction; direction comes from the index delta.
    @State private var shownTrack: Track?
    @State private var slideForward = true
    @State private var lastIndex = 0

    @State private var showAddToPlaylist = false
    @State private var showSongInfo = false
    @State private var showEQ = false

    /// Live offset while the card is being dragged down to dismiss.
    @State private var dragOffset: CGFloat = 0

    /// Square artwork sized so it never makes the layout wider than the screen.
    private var artSize: CGFloat {
        let b = UIScreen.main.bounds
        return min(b.width - 72, b.height * 0.40)
    }

    var body: some View {
        // Content respects the safe area (so it sits below the Dynamic Island);
        // only the blurred backdrop ignores it, as a full-bleed background.
        VStack(spacing: 16) {
            // Grab handle — drag it down (from any tab) to close the card.
            Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .gesture(dismissDrag)

            // The active pane fills the space; the Song / Lyrics / Queue switcher
            // now sits at the bottom, just above the home indicator.
            Group {
                switch tab {
                case .song: songPane.simultaneousGesture(dismissDrag)
                case .lyrics: LyricsPane()
                case .queue: QueuePane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Picker("", selection: $tab) {
                Text("Song").tag(Tab.song)
                Text("Lyrics").tag(Tab.lyrics)
                Text("Queue").tag(Tab.queue)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(backdrop)
        .preferredColorScheme(.dark)
        // Toasts render on MobileRoot, which this full-screen cover hides —
        // mirror them here so queue-tab actions (e.g. the Autoplay toggle)
        // give visible feedback.
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
        .sheet(isPresented: $showAddToPlaylist) {
            if let t = player.current { AddToPlaylistSheet(track: t) }
        }
        .sheet(isPresented: $showSongInfo) {
            if let t = player.current {
                SongInfoSheet(track: t, fromPlaylist: currentPlaylistName)
            }
        }
        .sheet(isPresented: $showEQ) {
            EqualizerSheet().environmentObject(player)
                .presentationDetents([.height(380), .large])
        }
    }

    /// Interactive drag-to-dismiss: the card tracks a downward drag and closes if
    /// pulled or flicked far enough, otherwise springs back. Direction-guarded so
    /// it never fights the horizontal track-swipe or vertical list scrolling
    /// (attached only to the handle and the non-scrolling Song pane).
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                let dy = v.translation.height
                if dy > 0, dy > abs(v.translation.width) { dragOffset = dy }
            }
            .onEnded { v in
                if v.translation.height > 120 || v.predictedEndTranslation.height > 500 {
                    player.showNowPlaying = false
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragOffset = 0 }
                }
            }
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
            ZStack {
                ArtworkView(url: shownTrack?.artworkURL, corner: 16)
                    .id(shownTrack?.videoId)
                    .transition(.asymmetric(
                        insertion: .move(edge: slideForward ? .trailing : .leading),
                        removal:   .move(edge: slideForward ? .leading  : .trailing)
                    ))
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            .scaleEffect(player.isPlaying ? 1 : 0.95)
            .animation(.spring(duration: 0.4), value: player.isPlaying)
            .trackSwipe(player)
            .contextMenu { trackActions }
            .onAppear { shownTrack = player.current; lastIndex = player.index }
            .onChange(of: player.current?.videoId) { _, _ in
                slideForward = player.index >= lastIndex
                lastIndex = player.index
                withAnimation(.easeInOut(duration: 0.32)) { shownTrack = player.current }
            }
            Spacer(minLength: 0)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    // Tap the title to open the album.
                    Text(player.current.map { NativeNames.displayTitle(for: $0) } ?? "").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { openAlbum() }
                    // Tap the artist to open the artist page.
                    Text(NativeNames.displayCached(player.current?.artistLine ?? "")).font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { openArtist() }
                }
                Spacer()
                Button { if let t = player.current { player.toggleLike(t) } } label: {
                    Image(systemName: player.current.map { player.likedIds.contains($0.videoId) } == true
                          ? "heart.fill" : "heart")
                        .font(.system(size: 22))
                        .foregroundStyle(player.current.map { player.likedIds.contains($0.videoId) } == true
                                         ? Theme.accent : .white.opacity(0.7))
                }
                Menu { trackActions } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 36)

            ProgressBar().padding(.horizontal, 36).padding(.top, 18)

            // Songs only — podcast episodes get their own screen
            // (PodcastNowPlayingScreen via NowPlayingSwitcher), so the two
            // transports can never mix again.
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
                // Was buried in the ••• menu; Charlie wanted it as its own
                // button, left of the sleep timer (2026-08-20). Copy Link
                // dropped from that menu at the same time — ShareLink's own
                // sheet already offers Copy, so it was a pure duplicate.
                if let url = shareURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                sleepMenu
                RoutePickerButton().frame(width: 26, height: 26)
                Button { player.showNowPlaying = false } label: {
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }

    /// Open the current track's album page (dismisses the now-playing screen).
    private func openAlbum() {
        guard let id = player.current?.album?.id, !id.isEmpty else { return }
        dismiss(); nav.go(.album(id))
    }

    /// Open the current track's (first) artist page.
    private func openArtist() {
        guard let a = player.current?.artists.first else { return }
        dismiss(); nav.goArtist(id: a.id, name: a.name)
    }

    private var shareURL: URL? { player.current?.shareURL }

    /// Name of the playlist the queue is playing from, if it's one of the
    /// user's library playlists (used in the Song Info sheet).
    private var currentPlaylistName: String? {
        guard let pid = player.playlistContextId else { return nil }
        return LibraryStore.shared.playlists.first { $0.playlistId == pid }?.title
    }

    /// Overflow actions, shared between the ••• menu and the artwork long-press.
    @ViewBuilder private var trackActions: some View {
        if player.current?.album?.id != nil {
            Button { openAlbum() } label: { Label("View Album", systemImage: "square.stack") }
        }
        if player.current?.artists.first != nil {
            Button { openArtist() } label: { Label("View Artist", systemImage: "music.mic") }
        }
        if let t = player.current {
            Button { player.playRadio(from: t) } label: {
                Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        Button { showAddToPlaylist = true } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
        if Equalizer.featureEnabled {
            Button { showEQ = true } label: { Label("Equalizer", systemImage: "slider.vertical.3") }
        }
        Button { showSongInfo = true } label: { Label("Song Info", systemImage: "info.circle") }
        if player.canRemoveCurrentFromPlaylist {
            Divider()
            Button(role: .destructive) { player.removeCurrentFromPlaylist() } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
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

/// Native output-route picker (AirPlay, Bluetooth, HomePod, built-in speaker).
/// It routes the app's audio session, which the hidden web player's inline audio
/// plays into — so picking a device here moves the music to it.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.6)
        picker.activeTintColor = UIColor(Theme.accent)
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
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
        .contentShape(Rectangle())
        .trackSwipe(player)
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
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Up Next").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button(editMode == .active ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Image(systemName: "infinity").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(player.autoplayEnabled ? Theme.accent : .white.opacity(0.3))
                Toggle("", isOn: $player.autoplayEnabled).labelsHidden().tint(Theme.accent)
                    .scaleEffect(0.8)
            }
            .padding(.horizontal, 24).padding(.bottom, 6)
            List {
                // Pin the current track to the top and only show what's coming
                // up — already-played tracks are hidden so the now-playing song
                // is always the first row.
                ForEach(Array(player.queue.enumerated().dropFirst(player.index)), id: \.offset) { i, track in
                    HStack(spacing: 11) {
                        ArtworkView(url: track.thumbnailURL, corner: 4).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NativeNames.displayTitle(for: track)).font(.system(size: 14, weight: i == player.index ? .semibold : .regular))
                                .foregroundStyle(i == player.index ? Theme.accent : .white).lineLimit(1)
                            Text(track.artistLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture { if editMode != .active { player.jump(to: i) } }
                    .id(i)
                }
                // List offsets are relative to the visible slice; shift them back
                // to absolute queue indices (the slice starts at player.index).
                .onMove { from, to in
                    let base = player.index
                    player.moveQueue(from: IndexSet(from.map { $0 + base }), to: to + base)
                }
                .onDelete { idx in
                    let base = player.index
                    idx.map { $0 + base }.sorted(by: >).forEach { player.removeFromQueue(at: $0) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
    }
}

extension View {
    /// Horizontal swipe to change track (left = next, right = previous), like the
    /// YouTube Music app. Uses simultaneousGesture so vertical lyric scrolling
    /// still works; only acts when the swipe is clearly horizontal.
    func trackSwipe(_ player: PlayerEngine) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    if v.translation.width < -55 { player.next() }
                    else if v.translation.width > 55 { player.previous() }
                }
        )
    }
}

/// Pick one of the user's playlists to add a track to.
struct AddToPlaylistSheet: View {
    /// One or many — the multi-select flow on collection pages adds a whole
    /// batch through the same sheet.
    let tracks: [Track]
    var onFinished: (() -> Void)?
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    init(track: Track) { self.tracks = [track] }
    init(tracks: [Track], onFinished: (() -> Void)? = nil) {
        self.tracks = tracks
        self.onFinished = onFinished
    }

    /// Only playlists you can actually add to — Liked Music and auto-radios
    /// are excluded (parity with the macOS context menu).
    private var playlists: [CardItem] {
        library.playlists.filter { pl in
            guard let id = pl.playlistId else { return false }
            return id != "LM" && !id.hasPrefix("RD")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list").font(.system(size: 34)).foregroundStyle(Theme.textTertiary)
                        Text("No playlists").foregroundStyle(Theme.textSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(playlists) { pl in
                        Button { add(pl) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: pl.thumbnailURL, corner: 5).frame(width: 46, height: 46)
                                Text(pl.title).font(.system(size: 16)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg)
            .navigationTitle(tracks.count > 1 ? "Add \(tracks.count) Songs" : "Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .task { await library.loadIfNeeded() }
    }

    private func add(_ pl: CardItem) {
        guard let pid = pl.playlistId else { return }
        dismiss()
        let batch = tracks
        Task {
            // YouTube happily stores the same song twice, so the duplicate
            // check has to happen here: pull what the playlist already holds
            // and drop anything it has.
            let existing = (try? await YTM.shared.playlist(id: pid).tracks) ?? []
            let split = PlaylistAdd.split(batch, existing: existing)

            var added = 0, failed = 0
            for track in split.toAdd {
                if (try? await YTM.shared.addToPlaylist(playlistId: pid, videoId: track.videoId)) == true {
                    added += 1
                } else {
                    failed += 1
                }
            }
            player.showToast(PlaylistAdd.resultMessage(added: added,
                                                       duplicates: split.duplicates.count,
                                                       failed: failed,
                                                       playlistTitle: pl.title))
            if added > 0 { PageCache.shared.collections["playlist-\(pid)"] = nil }
            onFinished?()
        }
    }
}

/// Read-only details for the current track.
struct SongInfoSheet: View {
    let track: Track
    var fromPlaylist: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ArtworkView(url: track.artworkURL, corner: 12)
                        .frame(width: 180, height: 180)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                        .padding(.top, 16)
                    VStack(spacing: 14) {
                        infoRow("Title", track.title)
                        if !track.artistLine.isEmpty { infoRow("Artist", track.artistLine) }
                        if let al = track.album?.name, !al.isEmpty { infoRow("Album", al) }
                        if !track.durationText.isEmpty { infoRow("Duration", track.durationText) }
                        if let fromPlaylist { infoRow("From Playlist", fromPlaylist) }
                    }
                    .padding(.horizontal, 22)
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle("Song Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 16)).foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
