import SwiftUI
import WebKit
import MediaPlayer
import EncoreCore

enum RepeatMode: Int {
    case off = 0, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

enum SleepTimerMode: Equatable {
    case off
    case time(Date)
    case songs(Int)

    var isActive: Bool { self != .off }
}

/// Playback position ticks 4×/second; isolating them here keeps those
/// updates from re-rendering every view that observes the engine (track
/// rows, shelves) — only the player bar and now-playing observe this.
@MainActor
final class PlayerClock: ObservableObject {
    static let shared = PlayerClock()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var lyrics: LyricsResult?
    @Published var lyricsLoading = false
    @Published var currentLyricIndex: Int? = nil

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }
}

/// Drives playback through a hidden WKWebView running the real
/// music.youtube.com page (the same approach pear-desktop/youtube-music uses):
/// a user script controls the site's `#movie_player`, so every track is
/// playable at Premium quality on the signed-in account, and plays count
/// toward recommendations. Everything around it (queue, shuffle, radio,
/// lyrics, media keys) is native.
@MainActor
final class PlayerEngine: NSObject, ObservableObject {
    static let shared = PlayerEngine()

    @Published var current: Track?
    @Published var queue: [Track] = []
    @Published var index: Int = 0
    @Published var isPlaying = false
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleOn = false
    @Published var likedIds: Set<String> = []
    @Published var showNowPlaying = false
    @Published var showSiteSettings = false
    @Published var sleepTimer: SleepTimerMode = .off
    /// Keep the music going with radio when the queue runs out (YT Music's
    /// "Autoplay").
    @Published var autoplayEnabled = true {
        didSet { UserDefaults.standard.set(autoplayEnabled, forKey: "autoplayEnabled") }
    }
    @Published var toast: String?
    @Published var videoMode = false {
        didSet { js("window.__encore && __encore.videoMode(\(videoMode ? "true" : "false"))") }
    }

    @Published var volume: Double = 0.85 {
        didSet {
            js("window.__encore && __encore.vol(\(Int(volume * 100)))")
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    let webView: WKWebView
    weak var parkContainer: NSView?
    let clock = PlayerClock.shared

    private(set) var currentTime: Double = 0 {
        didSet { clock.currentTime = currentTime }
    }
    private(set) var duration: Double = 0 {
        didSet { clock.duration = duration }
    }

    private var playerReady = false
    private var unshuffledQueue: [Track]?
    private var lyricsRequestId = 0
    private var fetchingMoreRadio = false
    private var toastTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    // When the sleep timer fires we must keep playback stopped even though
    // music.youtube.com may try to autoplay the next track on its own.
    private var sleepStopActive = false
    private var lastLoadAt = Date.distantPast
    private var mismatchTicks = 0
    private var loadedOnce = false
    private var restoreSeekTime: Double?
    private var lastTimePersist = Date.distantPast

    override private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(
            WKUserScript(source: Self.controllerScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        super.init()
        config.userContentController.add(BridgeHandler(engine: self), name: "bridge")
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        setupRemoteCommands()
        if UserDefaults.standard.object(forKey: "autoplayEnabled") != nil {
            autoplayEnabled = UserDefaults.standard.bool(forKey: "autoplayEnabled")
        }
        restoreSession()
    }

    // MARK: - Session persistence

    private struct Snapshot: Codable {
        var queue: [Track]
        var unshuffled: [Track]?
        var index: Int
        var shuffle: Bool
        var repeatRaw: Int
    }

    func persistSnapshot() {
        guard !queue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: "playerSnapshot")
            return
        }
        let snapshot = Snapshot(queue: Array(queue.prefix(300)),
                                unshuffled: unshuffledQueue.map { Array($0.prefix(300)) },
                                index: min(index, 299),
                                shuffle: shuffleOn,
                                repeatRaw: repeatMode.rawValue)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "playerSnapshot")
        }
        persistTime()
    }

    private func persistTime() {
        UserDefaults.standard.set(currentTime, forKey: "playerTime")
        lastTimePersist = Date()
    }

    private func restoreSession() {
        if UserDefaults.standard.object(forKey: "playerVolume") != nil {
            volume = UserDefaults.standard.double(forKey: "playerVolume")
        }
        guard let data = UserDefaults.standard.data(forKey: "playerSnapshot"),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.queue.isEmpty else { return }

        queue = snapshot.queue
        unshuffledQueue = snapshot.unshuffled
        index = min(max(snapshot.index, 0), snapshot.queue.count - 1)
        shuffleOn = snapshot.shuffle
        repeatMode = RepeatMode(rawValue: snapshot.repeatRaw) ?? .off
        current = queue[index]

        // Restore the queue and the current track, but always start it from the
        // beginning on reopen (by design — not from where you left off).
        duration = Double(current?.durationSeconds ?? 0)
        currentTime = 0
        restoreSeekTime = nil
        updateNowPlayingInfo()
    }

    // MARK: - Public playback API

    func playCollection(_ tracks: [Track], startAt: Int) {
        guard !tracks.isEmpty, startAt < tracks.count else { return }
        unshuffledQueue = nil
        shuffleOn = false
        queue = tracks
        index = startAt
        load(tracks[startAt])
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        unshuffledQueue = tracks
        shuffleOn = true
        queue = tracks.shuffled()
        index = 0
        load(queue[0])
    }

    /// Play a track immediately and grow a radio queue behind it.
    func playRadio(from track: Track) {
        unshuffledQueue = nil
        shuffleOn = false
        queue = [track]
        index = 0
        load(track)
        Task {
            guard let result = try? await YTM.shared.radioQueue(for: track.videoId),
                  !result.tracks.isEmpty else { return }
            guard self.current?.videoId == track.videoId else { return }
            var merged = [track]
            merged.append(contentsOf: result.tracks.filter { $0.videoId != track.videoId })
            self.queue = merged
            self.index = 0
        }
    }

    func playStation(playlistId: String, title: String) {
        showToast("Starting \(title)…")
        Task {
            guard let result = try? await YTM.shared.queue(videoId: nil, playlistId: playlistId),
                  !result.tracks.isEmpty else {
                self.showToast("Couldn't start \(title)")
                return
            }
            self.playCollection(result.tracks, startAt: result.currentIndex)
        }
    }

    func playNext(_ track: Track) {
        if queue.isEmpty || current == nil {
            playRadio(from: track)
            return
        }
        queue.insert(track, at: min(index + 1, queue.count))
        showToast("Playing next: \(track.title)")
        persistSnapshot()
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty || current == nil {
            playRadio(from: track)
            return
        }
        queue.append(track)
        showToast("Added to queue: \(track.title)")
        persistSnapshot()
    }

    func jump(to newIndex: Int) {
        guard newIndex >= 0, newIndex < queue.count else { return }
        index = newIndex
        load(queue[newIndex])
    }

    func removeFromQueue(at i: Int) {
        guard i >= 0, i < queue.count, i != index else { return }
        queue.remove(at: i)
        if i < index { index -= 1 }
        persistSnapshot()
    }

    /// Reorder the Up Next list; keep `index` pointing at the playing track.
    func moveQueue(from source: IndexSet, to destination: Int) {
        let currentId = current?.videoId
        queue.move(fromOffsets: source, toOffset: destination)
        unshuffledQueue = nil // manual order wins; don't let un-shuffle revert it
        if let currentId, let i = queue.firstIndex(where: { $0.videoId == currentId }) {
            index = i
        }
        persistSnapshot()
    }

    /// Jump a queued track to the top of Up Next (i.e. play it right after the
    /// current track). Used by the queue row's right-click menu.
    func playNext(from i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        moveQueueItem(from: i, to: i > index ? index + 1 : index)
    }

    /// Move a single queued track to land at `to` (drag-and-drop reorder).
    /// macOS rows drive reordering via `.draggable`/`.dropDestination` rather
    /// than `List.onMove`, so the indices are absolute, not SwiftUI offsets.
    func moveQueueItem(from: Int, to: Int) {
        guard from != to, queue.indices.contains(from), queue.indices.contains(to) else { return }
        let currentId = current?.videoId
        let item = queue.remove(at: from)
        queue.insert(item, at: to)
        unshuffledQueue = nil
        if let currentId, let i = queue.firstIndex(where: { $0.videoId == currentId }) {
            index = i
        }
        persistSnapshot()
    }

    func togglePlay() {
        guard let track = current else { return }
        sleepStopActive = false // explicit user intent overrides the sleep stop
        // First play after a restored session: start the web player directly at
        // the saved offset (reliable) instead of seeking after it begins at 0.
        if !loadedOnce {
            load(track, startAt: restoreSeekTime ?? 0)
            return
        }
        js(isPlaying ? "window.__encore && __encore.pause()" : "window.__encore && __encore.play()")
    }

    func next() {
        advance(manual: true)
    }

    func previous() {
        // Always go to the previous track; only restart when there's no
        // earlier track to go to (we're already at the first one).
        guard index > 0 else {
            seek(to: 0)
            return
        }
        index -= 1
        load(queue[index])
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        js("window.__encore && __encore.seek(\(seconds))")
        updateNowPlayingElapsed()
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: fraction * duration)
    }

    func toggleShuffle() {
        if shuffleOn {
            // Restore original order, keeping position on the current track.
            if let original = unshuffledQueue {
                queue = original
                if let cur = current, let i = original.firstIndex(where: { $0.videoId == cur.videoId }) {
                    index = i
                }
            }
            unshuffledQueue = nil
            shuffleOn = false
        } else {
            unshuffledQueue = queue
            guard !queue.isEmpty else { shuffleOn = true; return }
            var rest = queue
            let cur = index < rest.count ? rest.remove(at: index) : nil
            rest.shuffle()
            queue = (cur.map { [$0] } ?? []) + rest
            index = 0
            shuffleOn = true
        }
        persistSnapshot()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        persistSnapshot()
    }

    func toggleLike(_ track: Track) {
        let liked = likedIds.contains(track.videoId)
        if liked {
            likedIds.remove(track.videoId)
        } else {
            likedIds.insert(track.videoId)
            showToast("Added to Liked Music")
        }
        Task {
            try? await YTM.shared.setLiked(videoId: track.videoId, liked: !liked)
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimer = .time(end)
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self.fireSleepTimer()
        }
        showToast("Music will stop in \(minutes) min")
    }

    func setSleepTimer(songs: Int) {
        sleepTask?.cancel()
        sleepTimer = .songs(songs)
        showToast(songs == 1 ? "Stopping after this song" : "Stopping after \(songs) songs")
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTimer = .off
        sleepStopActive = false
        showToast("Sleep timer off")
    }

    private func fireSleepTimer() {
        sleepTask?.cancel()
        sleepTimer = .off
        sleepStopActive = true
        js("window.__encore && __encore.pause()")
        isPlaying = false
        updateNowPlayingInfo()
        showToast("Sleep timer — paused. Good night ♪")
    }

    /// Called when a song finishes naturally. Returns true if the timer fired
    /// and playback should stop instead of advancing.
    private func sleepTimerConsumedSong() -> Bool {
        guard case .songs(let remaining) = sleepTimer else { return false }
        if remaining <= 1 {
            fireSleepTimer()
            return true
        }
        sleepTimer = .songs(remaining - 1)
        return false
    }

    /// Reload the hidden site after the session changes (sign-in/out).
    func reloadSite() {
        playerReady = false
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
    }

    func park() {
        guard let container = parkContainer, webView.superview != container else { return }
        webView.removeFromSuperview()
        webView.frame = NSRect(x: 0, y: 0, width: 2, height: 2)
        container.addSubview(webView)
    }

    // MARK: - Internals

    private func load(_ track: Track, startAt: Double = 0) {
        loadedOnce = true
        // Carry the resume offset so the ready/state handlers can apply it too.
        restoreSeekTime = startAt > 0 ? startAt : nil
        sleepStopActive = false
        current = track
        currentTime = startAt
        duration = Double(track.durationSeconds ?? 0)
        clock.lyrics = nil
        clock.currentLyricIndex = nil
        lastLoadAt = Date()
        mismatchTicks = 0
        persistSnapshot()

        if playerReady {
            ensureJS(track.videoId, startAt: startAt)
        }

        updateNowPlayingInfo()
        fetchLyrics(for: track)
    }

    /// Load/resume a video in the web player, optionally from `startAt` seconds.
    private func ensureJS(_ videoId: String, startAt: Double) {
        if startAt > 0 {
            js("window.__encore && __encore.ensure('\(videoId)', \(startAt))")
        } else {
            js("window.__encore && __encore.ensure('\(videoId)')")
        }
    }

    private func advance(manual: Bool = false) {
        if !manual && repeatMode == .one {
            seek(to: 0)
            js("window.__encore && __encore.play()")
            return
        }
        if index + 1 < queue.count {
            index += 1
            load(queue[index])
            return
        }
        if repeatMode == .all && !queue.isEmpty {
            index = 0
            load(queue[0])
            return
        }
        // Queue exhausted: keep the music going with radio based on the last track.
        guard autoplayEnabled, let last = queue.last, !fetchingMoreRadio else {
            isPlaying = false
            return
        }
        fetchingMoreRadio = true
        Task {
            defer { self.fetchingMoreRadio = false }
            guard let result = try? await YTM.shared.radioQueue(for: last.videoId) else {
                self.isPlaying = false
                return
            }
            let existing = Set(self.queue.map(\.videoId))
            let fresh = result.tracks.filter { !existing.contains($0.videoId) }
            guard !fresh.isEmpty else {
                self.isPlaying = false
                return
            }
            self.queue.append(contentsOf: fresh)
            self.index += 1
            self.load(self.queue[self.index])
        }
    }

    func refetchLyrics() {
        guard let track = current else { return }
        clock.lyrics = nil
        clock.currentLyricIndex = nil
        fetchLyrics(for: track)
    }

    private func fetchLyrics(for track: Track) {
        lyricsRequestId += 1
        let requestId = lyricsRequestId
        clock.lyricsLoading = true
        Task {
            // One watch-queue fetch serves both the heart state (YouTube's
            // authoritative like status) and the lyrics browse id.
            let queueInfo = try? await YTM.shared.queue(videoId: track.videoId, playlistId: nil)
            if let status = queueInfo?.currentLikeStatus, self.current?.videoId == track.videoId {
                if status == "LIKE" {
                    self.likedIds.insert(track.videoId)
                } else {
                    self.likedIds.remove(track.videoId)
                }
            }
            let result = await LyricsService.shared.lyrics(for: track,
                                                           knownBrowseId: queueInfo?.lyricsBrowseId)
            guard requestId == self.lyricsRequestId else { return }
            self.clock.lyrics = result
            self.clock.lyricsLoading = false
        }
    }

    private func updateLyricIndex() {
        guard let lines = clock.lyrics?.lines, !lines.isEmpty else {
            if clock.currentLyricIndex != nil { clock.currentLyricIndex = nil }
            return
        }
        let nowMs = Int(currentTime * 1000)
        var idx: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.startMs <= nowMs { idx = i } else { break }
        }
        if idx != clock.currentLyricIndex {
            clock.currentLyricIndex = idx
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    /// Copy a shareable YouTube Music link for the current track to the
    /// clipboard, with a toast for feedback.
    func copyCurrentLink() {
        guard let url = current?.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("Link copied")
    }

    private func js(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Bridge events

    fileprivate func handleBridge(_ body: [String: Any]) {
        guard let event = body["event"] as? String else { return }
        switch event {
        case "ready":
            // Fires on every page load of the hidden web view. Only re-engage
            // the player if playback already started this session — a restored
            // session must stay paused until the user hits play.
            playerReady = true
            js("window.__encore && __encore.vol(\(Int(volume * 100)))")
            if loadedOnce, let track = current {
                ensureJS(track.videoId, startAt: restoreSeekTime ?? 0)
            }
        case "state":
            let state = body["data"] as? Int ?? -1
            switch state {
            case 1:
                // The sleep timer fired but the site auto-started a track —
                // force it back to paused.
                if sleepStopActive {
                    js("window.__encore && __encore.pause()")
                    isPlaying = false
                    break
                }
                isPlaying = true
                if let resumeAt = restoreSeekTime {
                    restoreSeekTime = nil
                    seek(to: resumeAt)
                }
            case 2:
                isPlaying = false
            case 0:
                isPlaying = false
                if reportedMatchesCurrent(body) {
                    if !sleepTimerConsumedSong() {
                        advance()
                    }
                }
            default:
                break
            }
            updateNowPlayingInfo()
        case "time":
            guard reportedMatchesCurrent(body) || Date().timeIntervalSince(lastLoadAt) < 6 else {
                // The site wandered off (its own autoplay); pull it back.
                mismatchTicks += 1
                if mismatchTicks > 8, let track = current {
                    mismatchTicks = 0
                    lastLoadAt = Date()
                    // Re-sync at our tracked position, not 0, so a glitch doesn't restart the song.
                    ensureJS(track.videoId, startAt: currentTime)
                }
                return
            }
            mismatchTicks = 0
            let t = body["t"] as? Double ?? 0
            let d = body["d"] as? Double ?? 0
            currentTime = t
            if d > 0 { duration = d }
            updateLyricIndex()
            if isPlaying, Date().timeIntervalSince(lastTimePersist) > 10 {
                persistTime()
            }
        default:
            break
        }
    }

    private func reportedMatchesCurrent(_ body: [String: Any]) -> Bool {
        guard let vid = body["vid"] as? String, !vid.isEmpty else { return true }
        return vid == current?.videoId
    }

    // MARK: - System now playing

    private var artworkCache: (videoId: String, artwork: MPMediaItemArtwork)?

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlay() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlay() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album?.name {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let cached = artworkCache, cached.videoId == track.videoId {
            info[MPMediaItemPropertyArtwork] = cached.artwork
        } else if let url = track.artworkURL {
            let videoId = track.videoId
            Task.detached {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run {
                    guard PlayerEngine.shared.current?.videoId == videoId else { return }
                    PlayerEngine.shared.artworkCache = (videoId, artwork)
                    var nowInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    nowInfo[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowInfo
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Injected controller

    /// Runs inside music.youtube.com and exposes a tiny control surface over
    /// the site's #movie_player (same player API as embeds, minus the embed
    /// restrictions). Reports state back over the script message bridge.
    static let controllerScript = #"""
    (function () {
      if (window.__encore) { return; }
      function send(o) {
        try { window.webkit.messageHandlers.bridge.postMessage(o); } catch (e) {}
      }
      function mp() { return document.getElementById('movie_player'); }

      var videoModeStyle = null;
      window.__encore = {
        ensure: function (id, start) {
          start = start || 0;
          var attempt = function (n) {
            var p = mp();
            if (p && p.loadVideoById && p.getVideoData) {
              var cur = p.getVideoData().video_id;
              if (cur !== id) {
                if (start > 0) { p.loadVideoById({ videoId: id, startSeconds: start }); }
                else { p.loadVideoById(id); }
              } else {
                if (start > 0 && p.seekTo) { p.seekTo(start, true); }
                if (p.getPlayerState && p.getPlayerState() !== 1) { p.playVideo(); }
              }
              // Watchdog: nudge playVideo() if the player ends up CUED (5) or
              // UNSTARTED (-1) instead of playing.
              var nudges = 0;
              var nudge = function () {
                var q = mp();
                if (!q || !q.getPlayerState || !q.getVideoData) { return; }
                if (q.getVideoData().video_id !== id) { return; }
                var s = q.getPlayerState();
                if (s === 5 || s === -1) {
                  q.playVideo();
                  if (++nudges < 6) { setTimeout(nudge, 350); }
                }
              };
              setTimeout(nudge, 400);
              return;
            }
            if (n <= 0) {
              location.href = 'https://music.youtube.com/watch?v=' + id + (start > 0 ? '&t=' + Math.floor(start) : '');
              return;
            }
            setTimeout(function () { attempt(n - 1); }, 300);
          };
          attempt(15);
        },
        play: function () { var p = mp(); if (p) p.playVideo(); },
        pause: function () { var p = mp(); if (p) p.pauseVideo(); },
        seek: function (s) { var p = mp(); if (p) p.seekTo(s, true); },
        vol: function (v) {
          var p = mp();
          if (p) { p.setVolume(v); if (v > 0 && p.isMuted && p.isMuted()) p.unMute(); }
        },
        videoMode: function (on) {
          if (!videoModeStyle) {
            videoModeStyle = document.createElement('style');
            videoModeStyle.textContent =
              'body.encore-video ytmusic-app * { visibility: hidden !important; }' +
              'body.encore-video video { visibility: visible !important; position: fixed !important;' +
              ' top: 0 !important; left: 0 !important; width: 100vw !important; height: 100vh !important;' +
              ' object-fit: contain; z-index: 99999; background: #000 !important; }' +
              'body.encore-video { background: #000 !important; }';
            document.head.appendChild(videoModeStyle);
          }
          document.body.classList.toggle('encore-video', !!on);
        }
      };

      // Event-driven state reporting: polling alone misses the brief "ended"
      // state when the site's own autoplay immediately starts loading the
      // next video.
      var hooked = null;
      function hookPlayer() {
        var p = mp();
        if (!p || p === hooked || !p.addEventListener) { return; }
        hooked = p;
        p.addEventListener('onStateChange', function (state) {
          var data = p.getVideoData ? p.getVideoData() : null;
          send({ event: 'state', data: state, vid: data ? data.video_id : null });
        });
      }

      var lastState = -9;
      setInterval(function () {
        hookPlayer();
        var p = mp();
        if (!p || !p.getPlayerState) { return; }
        var data = p.getVideoData ? p.getVideoData() : null;
        var vid = data ? data.video_id : null;
        var state = p.getPlayerState();
        if (state !== lastState) {
          lastState = state;
          send({ event: 'state', data: state, vid: vid });
        }
        send({ event: 'time', t: p.getCurrentTime() || 0, d: p.getDuration() || 0, vid: vid });
      }, 250);

      send({ event: 'ready' });
    })();
    """#
}

/// Separate handler object so the engine isn't retained by the user content controller.
private final class BridgeHandler: NSObject, WKScriptMessageHandler {
    weak var engine: PlayerEngine?

    init(engine: PlayerEngine) {
        self.engine = engine
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            self?.engine?.handleBridge(body)
        }
    }
}
