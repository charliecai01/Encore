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

/// Playback position ticks isolated from the engine so they don't re-render
/// every observing row.
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

/// iOS port of the desktop engine: hidden WKWebView drives the real
/// music.youtube.com player (desktop UA — the mobile site blocks playback),
/// native queue/radio/lyrics/media-center around it.
@MainActor
final class PlayerEngine: NSObject, ObservableObject {
    static let shared = PlayerEngine()

    @Published var current: Track? { didSet { onStateChange?() } }
    @Published var queue: [Track] = []
    @Published var index: Int = 0
    /// playlistId the current queue was played from, if it's an editable
    /// playlist. Enables "Remove from playlist" on the now-playing screen.
    /// nil for albums, radio, library songs, and home-shelf playback.
    @Published var playlistContextId: String?
    @Published var isPlaying = false { didSet { onStateChange?() } }
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleOn = false
    @Published var likedIds: Set<String> = []
    @Published var showNowPlaying = false
    @Published var sleepTimer: SleepTimerMode = .off
    @Published var toast: String?
    @Published var autoplayEnabled = true {
        didSet { UserDefaults.standard.set(autoplayEnabled, forKey: "autoplayEnabled") }
    }
    @Published var playbackRate: Double = 1.0 {
        didSet { UserDefaults.standard.set(playbackRate, forKey: "playbackRate") }
    }

    let webView: WKWebView
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
    private var sleepStopActive = false
    /// On a cold launch the real music.youtube.com session can auto-start the
    /// account's last track. Block any site-initiated playback until the user
    /// explicitly presses play.
    private var suppressSiteAutoplay = true
    /// Whether playback was active when an audio interruption (e.g. a phone
    /// call) began, so we know whether to resume when it ends.
    private var wasPlayingBeforeInterruption = false
    private var lastLoadAt = Date.distantPast
    private var mismatchTicks = 0
    private var loadedOnce = false
    private var restoreSeekTime: Double?
    private var lastTimePersist = Date.distantPast

    override private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        // Neutralize the site's Media Session BEFORE its JS runs, so iOS uses
        // our native MPNowPlayingInfoCenter (correct artwork + next/prev) instead
        // of YouTube's web session (which forces 10s skip buttons and its own,
        // out-of-sync metadata).
        config.userContentController.addUserScript(
            WKUserScript(source: Self.mediaSessionSuppressScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        config.userContentController.addUserScript(
            WKUserScript(source: Self.controllerScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        super.init()
        config.userContentController.add(BridgeHandler(engine: self), name: "bridge")
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        setupRemoteCommands()
        setupInterruptionHandling()
        if UserDefaults.standard.object(forKey: "autoplayEnabled") != nil {
            autoplayEnabled = UserDefaults.standard.bool(forKey: "autoplayEnabled")
        }
        if UserDefaults.standard.object(forKey: "playbackRate") != nil {
            let r = UserDefaults.standard.double(forKey: "playbackRate")
            if r > 0 { playbackRate = r }
        }
        restoreSession()
    }

    /// CarPlay observes this to refresh its now-playing/queue templates.
    var onStateChange: (() -> Void)?

    // MARK: - Session persistence (same keys as the Mac app)

    private struct Snapshot: Codable {
        var queue: [Track]
        var unshuffled: [Track]?
        var index: Int
        var shuffle: Bool
        var repeatRaw: Int
    }

    func persistSnapshot() {
        guard !queue.isEmpty else { return }
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
        guard let data = UserDefaults.standard.data(forKey: "playerSnapshot"),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.queue.isEmpty else { return }
        queue = snapshot.queue
        unshuffledQueue = snapshot.unshuffled
        index = min(max(snapshot.index, 0), snapshot.queue.count - 1)
        shuffleOn = snapshot.shuffle
        repeatMode = RepeatMode(rawValue: snapshot.repeatRaw) ?? .off
        current = queue[index]
        let savedTime = UserDefaults.standard.double(forKey: "playerTime")
        duration = Double(current?.durationSeconds ?? 0)
        // Only clamp when the duration is known; otherwise keep the saved time
        // verbatim (clamping against an unknown 0 duration collapsed it to 0:00,
        // which is why restored tracks always restarted). If we were within ~2s
        // of the end last time, start fresh instead of resuming at the finish.
        if duration > 1, savedTime > duration - 2 {
            currentTime = 0
        } else {
            currentTime = savedTime
        }
        restoreSeekTime = currentTime > 1 ? currentTime : nil
        updateNowPlayingInfo()
    }

    // MARK: - Public playback API

    func playCollection(_ tracks: [Track], startAt: Int, playlistId: String? = nil) {
        guard !tracks.isEmpty, startAt < tracks.count else { return }
        unshuffledQueue = nil
        shuffleOn = false
        playlistContextId = playlistId
        queue = tracks
        index = startAt
        load(tracks[startAt])
    }

    func playShuffled(_ tracks: [Track], playlistId: String? = nil) {
        guard !tracks.isEmpty else { return }
        unshuffledQueue = tracks
        shuffleOn = true
        playlistContextId = playlistId
        queue = tracks.shuffled()
        index = 0
        load(queue[0])
    }

    func playRadio(from track: Track) {
        unshuffledQueue = nil
        shuffleOn = false
        playlistContextId = nil
        queue = [track]
        index = 0
        load(track)
        Task {
            guard let result = try? await YTM.shared.radioQueue(for: track.videoId),
                  !result.tracks.isEmpty,
                  self.current?.videoId == track.videoId else { return }
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
        guard !queue.isEmpty, current != nil else {
            playRadio(from: track)
            return
        }
        queue.insert(track, at: min(index + 1, queue.count))
        showToast("Playing next: \(track.title)")
        persistSnapshot()
    }

    func addToQueue(_ track: Track) {
        guard !queue.isEmpty, current != nil else {
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

    /// Whether the now-playing track can be removed from the playlist it's
    /// being played from (requires an editable playlist context).
    var canRemoveCurrentFromPlaylist: Bool {
        playlistContextId != nil && current != nil
    }

    /// Remove the currently-playing track from the playlist it was played from.
    /// Keeps the song playing, drops any other copies from Up Next, and updates
    /// the cached playlist page so the list reflects it.
    func removeCurrentFromPlaylist() {
        guard let playlistId = playlistContextId, let track = current else { return }
        Task {
            let ok = (try? await YTM.shared.removeFromPlaylist(
                playlistId: playlistId, videoId: track.videoId, setVideoId: track.setVideoId)) ?? false
            guard ok else {
                self.showToast("Couldn't remove — you can only edit your own playlists")
                return
            }
            // Update the cached playlist page so the playlist screen updates too.
            let key = "playlist-\(playlistId)"
            if var cached = PageCache.shared.collections[key] {
                cached.tracks.removeAll { $0.videoId == track.videoId && $0.setVideoId == track.setVideoId }
                PageCache.shared.collections[key] = cached
            }
            // Drop other copies from Up Next; keep the one playing right now.
            let playingIdx = self.index
            var rebuilt: [Track] = []
            for (i, t) in self.queue.enumerated() {
                if i == playingIdx || !(t.videoId == track.videoId && t.setVideoId == track.setVideoId) {
                    rebuilt.append(t)
                }
            }
            self.queue = rebuilt
            self.unshuffledQueue = nil
            if let cur = self.current,
               let i = rebuilt.firstIndex(where: { $0.videoId == cur.videoId && $0.setVideoId == cur.setVideoId }) {
                self.index = i
            }
            self.persistSnapshot()
            self.showToast("Removed from playlist")
        }
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

    func togglePlay() {
        guard let track = current else { return }
        sleepStopActive = false
        suppressSiteAutoplay = false // explicit user intent overrides the launch guard
        if !loadedOnce {
            // First play after a restored session: start the web player directly
            // at the saved offset (reliable) instead of seeking after it starts.
            load(track, startAt: restoreSeekTime ?? 0)
            return
        }
        if isPlaying {
            js("window.__encore && __encore.pause()")
        } else {
            // Resuming: the audio session may have gone inactive while paused/
            // backgrounded — reactivate it or play() produces no sound (and the
            // user has to skip to force a reload). This is the resume-lag fix.
            try? AVAudioSession.sharedInstance().setActive(true)
            js("window.__encore && __encore.play()")
        }
    }

    func next() {
        advance(manual: true)
    }

    func previous() {
        if currentTime > 3 || index == 0 {
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

    /// Skip forward/back by a number of seconds (podcast controls).
    func skip(_ delta: Double) {
        let target = currentTime + delta
        let upper = duration > 0 ? duration : target
        seek(to: max(0, min(target, upper)))
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        js("window.__encore && __encore.rate(\(rate))")
    }

    func toggleShuffle() {
        if shuffleOn {
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
        Task { try? await YTM.shared.setLiked(videoId: track.videoId, liked: !liked) }
    }

    func reloadSite() {
        playerReady = false
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
    }

    func refetchLyrics() {
        guard let track = current else { return }
        clock.lyrics = nil
        clock.currentLyricIndex = nil
        fetchLyrics(for: track)
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        sleepTimer = .time(Date().addingTimeInterval(Double(minutes) * 60))
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

    private func sleepTimerConsumedSong() -> Bool {
        guard case .songs(let remaining) = sleepTimer else { return false }
        if remaining <= 1 {
            fireSleepTimer()
            return true
        }
        sleepTimer = .songs(remaining - 1)
        return false
    }

    // MARK: - Internals

    private func load(_ track: Track, startAt: Double = 0) {
        loadedOnce = true
        // Carry the resume offset so the ready/state handlers can apply it too.
        restoreSeekTime = startAt > 0 ? startAt : nil
        sleepStopActive = false
        suppressSiteAutoplay = false
        current = track
        currentTime = startAt
        duration = Double(track.durationSeconds ?? 0)
        clock.lyrics = nil
        clock.currentLyricIndex = nil
        lastLoadAt = Date()
        mismatchTicks = 0
        persistSnapshot()
        try? AVAudioSession.sharedInstance().setActive(true)
        if playerReady {
            ensureJS(track.videoId, startAt: startAt)
        }
        updateNowPlayingInfo()
        fetchLyrics(for: track)
    }

    /// Tell the web player to load/resume a video, optionally from `startAt`
    /// seconds (so a restored session begins where you left off, not at 0:00).
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

    private func fetchLyrics(for track: Track) {
        lyricsRequestId += 1
        let requestId = lyricsRequestId
        clock.lyricsLoading = true
        Task {
            let result = await LyricsService.shared.lyrics(for: track)
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

    private func js(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Bridge events

    fileprivate func handleBridge(_ body: [String: Any]) {
        guard let event = body["event"] as? String else { return }
        switch event {
        case "remote":
            // Lock-screen / headphone next-prev coming back through the page's
            // MediaSession handlers (which we hijacked to drive our queue).
            switch body["action"] as? String {
            case "next": next()
            case "prev": previous()
            default: break
            }
        case "ready":
            playerReady = true
            if loadedOnce, let track = current {
                ensureJS(track.videoId, startAt: restoreSeekTime ?? 0)
            }
        case "state":
            let state = body["data"] as? Int ?? -1
            switch state {
            case 1:
                if sleepStopActive || suppressSiteAutoplay {
                    js("window.__encore && __encore.pause()")
                    isPlaying = false
                    break
                }
                isPlaying = true
                if playbackRate != 1.0 {
                    js("window.__encore && __encore.rate(\(playbackRate))")
                }
                if let resumeAt = restoreSeekTime {
                    restoreSeekTime = nil
                    seek(to: resumeAt)
                }
            case 2:
                isPlaying = false
            case 0:
                isPlaying = false
                if reportedMatchesCurrent(body), !sleepTimerConsumedSong() {
                    advance()
                }
            default:
                break
            }
            updateNowPlayingInfo()
        case "time":
            guard reportedMatchesCurrent(body) || Date().timeIntervalSince(lastLoadAt) < 6 else {
                mismatchTicks += 1
                if mismatchTicks > 8, !suppressSiteAutoplay, let track = current {
                    mismatchTicks = 0
                    lastLoadAt = Date()
                    // Re-sync at our tracked position, not 0, so a glitch doesn't restart the song.
                    ensureJS(track.videoId, startAt: currentTime)
                }
                return
            }
            mismatchTicks = 0
            currentTime = body["t"] as? Double ?? 0
            if let d = body["d"] as? Double, d > 0 { duration = d }
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

    // MARK: - System now playing (lock screen + CarPlay)

    private var artworkCache: (videoId: String, artwork: MPMediaItemArtwork)?

    // MARK: - Audio interruptions (phone calls, Siri, other apps)

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            DispatchQueue.main.async {
                self?.handleInterruption(began: type == .began, shouldResume: shouldResume)
            }
        }
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            // The system has already ducked/paused our audio; mirror it in our
            // state and remember whether to resume afterward.
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                js("window.__encore && __encore.pause()")
                isPlaying = false
                updateNowPlayingInfo()
            }
        } else {
            defer { wasPlayingBeforeInterruption = false }
            guard shouldResume, wasPlayingBeforeInterruption,
                  !sleepStopActive, current != nil else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            js("window.__encore && __encore.play()")
        }
    }

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
        // Podcast-style skip (only surfaced for episodes — see configureRemoteCommands).
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skip(30) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skip(-15) }
            return .success
        }
        configureRemoteCommands(forEpisode: false)
    }

    /// Songs get next/previous on the lock screen; podcast episodes get skip.
    private func configureRemoteCommands(forEpisode: Bool) {
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = !forEpisode
        c.previousTrackCommand.isEnabled = !forEpisode
        c.skipForwardCommand.isEnabled = forEpisode
        c.skipBackwardCommand.isEnabled = forEpisode
    }

    private func updateNowPlayingInfo() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        configureRemoteCommands(forEpisode: track.isEpisode)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
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
                      let image = UIImage(data: data) else { return }
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
    }

    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Injected scripts

    /// On iOS the WKWebView owns the lock-screen now-playing via the page's
    /// MediaSession — our native MPNowPlayingInfoCenter is ignored there. So we
    /// keep the site's metadata (correct title + artwork) but hijack its action
    /// handlers: drop the web 'seek' actions (which forced 10s-skip buttons) and
    /// route next/previous to OUR queue. Runs at documentStart so the override is
    /// in place before the site binds its own handlers.
    static let mediaSessionSuppressScript = #"""
    (function () {
      try {
        if (!('mediaSession' in navigator)) return;
        var ms = navigator.mediaSession;
        if (ms.__encorePatched) return;
        ms.__encorePatched = true;
        var orig = ms.setActionHandler.bind(ms);
        function bridge(action) {
          return function () {
            try { window.webkit.messageHandlers.bridge.postMessage({ event: 'remote', action: action }); } catch (e) {}
          };
        }
        function apply() {
          try {
            orig('seekforward', null);
            orig('seekbackward', null);
            orig('seekto', null);
            orig('nexttrack', bridge('next'));
            orig('previoustrack', bridge('prev'));
          } catch (e) {}
        }
        // Ignore the site's seek handlers; force next/prev to ours; pass the rest.
        ms.setActionHandler = function (action, handler) {
          if (action === 'seekforward' || action === 'seekbackward' || action === 'seekto') return;
          if (action === 'nexttrack') return orig('nexttrack', bridge('next'));
          if (action === 'previoustrack') return orig('previoustrack', bridge('prev'));
          return orig(action, handler);
        };
        apply();
        setInterval(apply, 2000); // re-assert if the site rebinds on track change
      } catch (e) {}
    })();
    """#

    static let controllerScript = #"""
    (function () {
      if (window.__encore) { return; }
      function send(o) {
        try { window.webkit.messageHandlers.bridge.postMessage(o); } catch (e) {}
      }
      function mp() { return document.getElementById('movie_player'); }

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
              // Watchdog: iOS autoplay policy can leave the player CUED (5) or
              // UNSTARTED (-1) instead of playing, which used to require skipping
              // a track to recover. Nudge playVideo() until it actually starts.
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
        rate: function (r) { var p = mp(); if (p && p.setPlaybackRate) { try { p.setPlaybackRate(r); } catch (e) {} } },
        vol: function (v) {
          var p = mp();
          if (p) { p.setVolume(v); if (v > 0 && p.isMuted && p.isMuted()) p.unMute(); }
        }
      };

      // Event-driven state reporting: polling alone misses the brief "ended"
      // state when the site's own autoplay immediately starts loading the next
      // video — which leaves our queue behind and yanks playback back to the
      // previous track. The onStateChange hook catches it so we advance in sync.
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
