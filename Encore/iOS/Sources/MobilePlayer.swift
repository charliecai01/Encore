import SwiftUI
import WebKit
import MediaPlayer
import AVFoundation
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
        didSet {
            UserDefaults.standard.set(autoplayEnabled, forKey: "autoplayEnabled")
            // Mirror the site's toggle: ON populates the queue tail right
            // away; OFF strips the not-yet-played autoplay tracks so the
            // queue returns to just your own songs.
            if autoplayEnabled && !oldValue { prefetchAutoplayTail() }
            if !autoplayEnabled && oldValue { removeAutoplayTail() }
        }
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
    /// The in-flight autoplay radio fetch, shared so a tail prefetch and the
    /// end-of-queue advance never race — advance awaits the same fetch.
    private var radioFetchTask: Task<Bool, Never>?
    private var advancingViaRadio = false
    /// videoIds appended by autoplay extensions — the removable tail when the
    /// Autoplay toggle turns off. User-queued songs are never in here.
    private var autoplayTailIds: Set<String> = []
    /// Endless-radio cursor from the active radio. Autoplay continues the radio
    /// with this instead of re-seeding `RDAMVM…`, which returns the same songs
    /// each time and dead-ends after dedup. nil for finite, non-radio queues.
    private var radioContinuation: String?
    private var toastTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var sleepStopActive = false
    /// On a cold launch the real music.youtube.com session can auto-start the
    /// account's last track. Block any site-initiated playback until the user
    /// explicitly presses play.
    private var suppressSiteAutoplay = true
    /// The user's playback intent — true while they want music playing. Unlike
    /// the momentary `isPlaying`, this survives interruptions (a phone call, a
    /// loud Instagram Reel), so we resume when each interruption ends — even
    /// through rapid back-to-back interruptions where `isPlaying` is briefly
    /// false mid-recovery.
    private var userWantsPlayback = false
    private var lastLoadAt = Date.distantPast
    private var mismatchTicks = 0
    private var loadedOnce = false
    /// Force the next web-player engage to do a clean loadVideoById rather than
    /// resuming whatever the site auto-loaded. Set for the first play after a
    /// restored session, so we don't inherit the site's auto-resumed track and
    /// its radio "Up Next" (which would override our restored queue).
    private var forceReloadOnEngage = false
    private var restoreSeekTime: Double?
    private var lastTimePersist = Date.distantPast
    /// The videoId actually loaded in the web player. Equals the current track's
    /// id for songs/episodes; for a music video it's the audio counterpart we
    /// swap in (iOS suspends WKWebView video in the background, so we play audio).
    /// Site state/time reports are matched against this, not the track's own id.
    private var playingVideoId: String?
    /// Cache of resolved playback ids (audio counterpart, or the id itself when
    /// there's none) so replaying a music video skips the lookup.
    private var resolvedPlaybackId: [String: String] = [:]
    // Stall watchdog: the furthest playback position we've seen and when, used to
    // detect a frozen stream (weak cellular) and re-establish it.
    private var lastProgressT = 0.0
    private var lastProgressAt = Date.distantPast
    private var stallNudged = false
    /// Guards one play-count increment per track load (recorded after a threshold).
    private var playCountRecorded = false
    // Silent looping player that holds the audio session (and the Now Playing
    // slot) while paused — see the keep-alive section.
    private var keepAlivePlayer: AVAudioPlayer?

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
        // Restore the queue and the current track, but always start it from the
        // beginning on reopen (by design — not from where you left off).
        duration = Double(current?.durationSeconds ?? 0)
        currentTime = 0
        restoreSeekTime = nil
        Log.player.notice("restore: \(snapshot.queue.count) tracks, index=\(self.index), current=\(self.current?.videoId ?? "nil") '\(self.current?.title ?? "")'")
        updateNowPlayingInfo()
    }

    // MARK: - Public playback API

    func playCollection(_ tracks: [Track], startAt: Int, playlistId: String? = nil) {
        guard !tracks.isEmpty, startAt < tracks.count else { return }
        unshuffledQueue = nil
        shuffleOn = false
        playlistContextId = playlistId
        radioContinuation = nil // finite context; radio is seeded fresh when it ends
        autoplayTailIds = []
        queue = tracks
        index = startAt
        load(tracks[startAt])
    }

    func playShuffled(_ tracks: [Track], playlistId: String? = nil) {
        guard !tracks.isEmpty else { return }
        unshuffledQueue = tracks
        shuffleOn = true
        playlistContextId = playlistId
        radioContinuation = nil
        autoplayTailIds = []
        queue = tracks.shuffled()
        index = 0
        load(queue[0])
    }

    func playRadio(from track: Track) {
        unshuffledQueue = nil
        shuffleOn = false
        playlistContextId = nil
        radioContinuation = nil
        autoplayTailIds = []
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
            self.radioContinuation = result.continuation
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
            self.radioContinuation = result.continuation // playCollection cleared it
        }
    }

    func playNext(_ track: Track) {
        guard !queue.isEmpty, current != nil else {
            playRadio(from: track)
            return
        }
        autoplayTailIds.remove(track.videoId) // explicitly queued = user's own
        queue.insert(track, at: min(index + 1, queue.count))
        showToast("Playing next: \(track.title)")
        persistSnapshot()
    }

    func addToQueue(_ track: Track) {
        guard !queue.isEmpty, current != nil else {
            playRadio(from: track)
            return
        }
        autoplayTailIds.remove(track.videoId) // explicitly queued = user's own
        // Land after the user's own queue but before the autoplay tail, like
        // the site — the tail stays at the very end.
        var insertAt = queue.count
        while insertAt > index + 1, autoplayTailIds.contains(queue[insertAt - 1].videoId) {
            insertAt -= 1
        }
        queue.insert(track, at: insertAt)
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
            // Force a clean load so we replace the site's auto-resumed session
            // (often the same track, carrying its own radio queue) with ours.
            Log.player.notice("firstPlay(restored): current=\(track.videoId) '\(track.title)', forcing clean load")
            forceReloadOnEngage = true
            load(track, startAt: restoreSeekTime ?? 0)
            return
        }
        if isPlaying {
            userWantsPlayback = false
            js("window.__encore && __encore.pause()")
            // Hold the audio session so the Now Playing widget survives a long
            // background pause (the web player would otherwise give it up).
            startKeepAlive()
        } else {
            // Resuming: the audio session may have gone inactive while paused/
            // backgrounded — reactivate it or play() produces no sound (and the
            // user has to skip to force a reload). This is the resume-lag fix.
            userWantsPlayback = true
            stopKeepAlive()
            try? AVAudioSession.sharedInstance().setActive(true)
            js("window.__encore && __encore.play()")
        }
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
        userWantsPlayback = false
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
        userWantsPlayback = true // loading a track is an intent to play
        stopKeepAlive() // a real track is about to play
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
        lastProgressT = startAt
        lastProgressAt = Date()
        playCountRecorded = false
        persistSnapshot()
        try? AVAudioSession.sharedInstance().setActive(true)
        if playerReady {
            startPlayback(track, startAt: startAt)
        }
        updateNowPlayingInfo()
        fetchLyrics(for: track)
    }

    /// Start `track` in the web player. Music videos are swapped for their
    /// audio counterpart first: iOS suspends WKWebView video the moment the
    /// screen locks, so playing the audio track keeps lock-screen playback alive
    /// (the video is never shown on iOS anyway) and uses less data. Falls back to
    /// the video itself when there's no counterpart.
    private func startPlayback(_ track: Track, startAt: Double) {
        let canonicalId = track.videoId
        // Songs and episodes play directly.
        guard track.isVideo, !track.isEpisode else {
            playingVideoId = canonicalId
            engageJS(canonicalId, track: track, startAt: startAt)
            return
        }
        // Resolved before — reuse it (audio counterpart, or the id itself).
        if let resolved = resolvedPlaybackId[canonicalId] {
            playingVideoId = resolved
            engageJS(resolved, track: track, startAt: startAt)
            return
        }
        // Hold off engaging the video element until we know the audio id, so a
        // video-backed element never actually starts (and never gets suspended
        // on lock). Site reports in the meantime are ignored by the 6s post-load
        // grace in the `time` handler.
        playingVideoId = canonicalId
        Task {
            let audioId = await YTM.shared.audioCounterpart(for: canonicalId)
            let idToPlay = audioId ?? canonicalId
            self.resolvedPlaybackId[canonicalId] = idToPlay
            guard self.current?.videoId == canonicalId else { return }
            self.playingVideoId = idToPlay
            self.engageJS(idToPlay, track: track, startAt: startAt)
        }
    }

    /// Load a videoId into the web player and apply per-track playback settings.
    private func engageJS(_ videoId: String, track: Track, startAt: Double) {
        ensureJS(videoId, startAt: startAt)
        pushMediaSessionMeta()
        // Episodes keep the chosen speed; songs are forced back to 1×.
        js("window.__encore && __encore.rate(\(track.isEpisode ? playbackRate : 1.0))")
        js("window.__encore && __encore.lowData()")
    }

    /// Drive the lock-screen / Control Center metadata through the page's
    /// MediaSession with OUR current track, so the displayed artwork/title can't
    /// lag behind the song we loaded via loadVideoById.
    private func pushMediaSessionMeta() {
        guard playerReady, let track = current else { return }
        let meta: [String: Any] = [
            "title": track.title,
            "artist": track.artistLine,
            "album": track.album?.name ?? "",
            "art": track.artworkURL?.absoluteString ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: meta),
              let json = String(data: data, encoding: .utf8) else { return }
        js("window.__encore && __encore.setMeta(\(json))")
    }

    /// Tell the web player to load/resume a video, optionally from `startAt`
    /// seconds (so a restored session begins where you left off, not at 0:00).
    private func ensureJS(_ videoId: String, startAt: Double) {
        // Consume the one-shot force flag: the first engage after a restored
        // session does a clean loadVideoById so it doesn't inherit the site's
        // auto-resumed radio. Later engages (stalls, re-syncs) resume in place.
        let force = forceReloadOnEngage
        forceReloadOnEngage = false
        let f = force ? "true" : "false"
        if startAt > 0 {
            js("window.__encore && __encore.ensure('\(videoId)', \(startAt), \(f))")
        } else {
            js("window.__encore && __encore.ensure('\(videoId)', 0, \(f))")
        }
    }

    private func advance(manual: Bool = false) {
        Log.player.notice("advance(manual:\(manual)): index=\(self.index)/\(self.queue.count) repeat=\(self.repeatMode.rawValue)")
        if !manual && repeatMode == .one {
            seek(to: 0)
            js("window.__encore && __encore.play()")
            return
        }
        if index + 1 < queue.count {
            index += 1
            load(queue[index])
            // Entering the last queued track: line up the autoplay tail now
            // so the queue shows what's next and the handoff has no fetch gap.
            if index == queue.count - 1 { prefetchAutoplayTail() }
            return
        }
        if repeatMode == .all && !queue.isEmpty {
            index = 0
            load(queue[0])
            return
        }
        guard autoplayEnabled, !queue.isEmpty, !advancingViaRadio else {
            isPlaying = false
            return
        }
        advancingViaRadio = true
        Log.player.notice("advance: queue exhausted, extending radio (hasContinuation=\(self.radioContinuation != nil))")
        let fetch = ensureRadioFetch()
        Task {
            defer { self.advancingViaRadio = false }
            _ = await fetch.value
            if self.index + 1 < self.queue.count {
                self.index += 1
                self.load(self.queue[self.index])
                Log.player.notice("advance: radio extended -> index=\(self.index) '\(self.queue[self.index].title)'")
            } else {
                self.isPlaying = false
                Log.player.notice("advance: radio extend found nothing new; stopping")
            }
        }
    }

    /// The single in-flight radio fetch — reused if one is already running so
    /// the toggle/last-track prefetch and the end-of-queue advance share work.
    @discardableResult
    private func ensureRadioFetch() -> Task<Bool, Never> {
        if let task = radioFetchTask { return task }
        let task = Task { () -> Bool in
            defer { self.radioFetchTask = nil }
            return await self.extendQueueWithRadio()
        }
        radioFetchTask = task
        return task
    }

    /// Populate the queue tail with upcoming autoplay tracks ahead of time —
    /// when the toggle turns on and when playback reaches the last queued
    /// track — so the queue shows what's next. Append-only; never changes
    /// what's playing.
    private func prefetchAutoplayTail() {
        guard autoplayEnabled, repeatMode == .off, !queue.isEmpty else { return }
        Log.player.notice("autoplay: prefetching radio tail (hasContinuation=\(self.radioContinuation != nil))")
        ensureRadioFetch()
    }

    /// Strip not-yet-played autoplay tracks from the queue — the site's
    /// behavior when the Autoplay toggle turns off. Rows at or before the
    /// current index stay (already played / playing); the user's own songs
    /// are never touched.
    private func removeAutoplayTail() {
        guard !autoplayTailIds.isEmpty, !queue.isEmpty else { return }
        let before = queue.count
        let keepThrough = index
        var kept: [Track] = []
        kept.reserveCapacity(queue.count)
        for (i, t) in queue.enumerated() {
            if i > keepThrough && autoplayTailIds.contains(t.videoId) { continue }
            kept.append(t)
        }
        guard kept.count != before else { return }
        queue = kept
        Log.player.notice("autoplay off: removed \(before - kept.count) autoplay tracks -> \(kept.count) in queue")
        persistSnapshot()
    }

    /// Pull more autoplay tracks when the queue runs out. Continues the active
    /// radio via its continuation cursor (genuinely new songs); if there's no
    /// cursor or it returns nothing new, seeds a fresh radio from the last track.
    /// Returns whether any new tracks were appended.
    private func extendQueueWithRadio() async -> Bool {
        guard let last = queue.last else { return false }
        func merge(_ result: QueueResult?) -> Bool {
            // Re-check the toggle at append time — it may have been switched
            // off while the fetch was in flight.
            guard let result, autoplayEnabled else { return false }
            // Advance the cursor even when a page is all dupes, so the next
            // attempt pulls the following page instead of repeating this one.
            if let token = result.continuation { radioContinuation = token }
            let existing = Set(queue.map(\.videoId))
            let fresh = result.tracks.filter { !existing.contains($0.videoId) }
            guard !fresh.isEmpty else { return false }
            queue.append(contentsOf: fresh)
            autoplayTailIds.formUnion(fresh.map(\.videoId))
            return true
        }
        if let token = radioContinuation,
           merge(try? await YTM.shared.queueContinuation(token)) {
            return true
        }
        return merge(try? await YTM.shared.radioQueue(for: last.videoId))
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
            Log.player.notice("ready: loadedOnce=\(self.loadedOnce) current=\(self.current?.videoId ?? "nil")")
            if loadedOnce, let track = current {
                startPlayback(track, startAt: restoreSeekTime ?? 0)
            }
        case "engage":
            // Diagnostic: what the web player already had loaded (the site's
            // auto-resumed session) vs. the track we asked for, and whether we
            // forced a clean load. This is the smoking gun for restore-then-play.
            Log.player.notice("engage: site cur=\(body["cur"] as? String ?? "nil") want=\(body["id"] as? String ?? "nil") force=\(body["force"] as? Bool ?? false) -> \(body["action"] as? String ?? "?")")
        case "state":
            let state = body["data"] as? Int ?? -1
            Log.player.notice("state=\(state) vid=\(body["vid"] as? String ?? "nil") current=\(self.current?.videoId ?? "nil") suppress=\(self.suppressSiteAutoplay)")
            switch state {
            case 1:
                if sleepStopActive || suppressSiteAutoplay {
                    js("window.__encore && __encore.pause()")
                    isPlaying = false
                    break
                }
                isPlaying = true
                stopKeepAlive() // real audio is playing now
                lastProgressAt = Date() // (re)started — reset the stall watchdog
                // Playback speed applies to podcast episodes only. Songs always
                // play at 1× — otherwise the web player carries an episode's rate
                // onto the next song for a few seconds before resetting.
                let rate = current?.isEpisode == true ? playbackRate : 1.0
                js("window.__encore && __encore.rate(\(rate))")
                if let resumeAt = restoreSeekTime {
                    restoreSeekTime = nil
                    seek(to: resumeAt)
                }
            case 2:
                isPlaying = false
            case 0:
                isPlaying = false
                // Only advance on a *trustworthy* end-of-song. The page can briefly
                // report ENDED with a missing/blank video id during ads or buffering
                // glitches — those used to skip the song ~10s in. Require either a
                // confirmed video-id match or that we're genuinely near the end.
                let endedVid = body["vid"] as? String
                let confirmedEnd = !(endedVid ?? "").isEmpty && endedVid == activePlaybackId
                let nearEnd = duration > 0 && currentTime >= duration - 6
                if (confirmedEnd || nearEnd), !sleepTimerConsumedSong() {
                    advance()
                }
            default:
                break
            }
            updateNowPlayingInfo()
        case "time":
            guard reportedMatchesCurrent(body) || Date().timeIntervalSince(lastLoadAt) < 6 else {
                mismatchTicks += 1
                if mismatchTicks > 8, !suppressSiteAutoplay, let playId = activePlaybackId {
                    mismatchTicks = 0
                    lastLoadAt = Date()
                    // Re-sync at our tracked position, not 0, so a glitch doesn't restart the song.
                    ensureJS(playId, startAt: currentTime)
                }
                return
            }
            mismatchTicks = 0
            let t = body["t"] as? Double ?? 0
            // Stall watchdog: on weak cellular the stream can stop buffering and
            // playback freezes (position stops advancing) with no ended/pause
            // event. If we're "playing" but haven't moved for a while, re-establish
            // the stream at our current spot so it recovers instead of dying.
            if isPlaying {
                if abs(t - lastProgressT) > 0.4 {
                    // Position moved (normal play, or a seek) — not stalled.
                    lastProgressT = t
                    lastProgressAt = Date()
                    stallNudged = false
                } else if Date().timeIntervalSince(lastLoadAt) > 5, let playId = activePlaybackId {
                    let frozen = Date().timeIntervalSince(lastProgressAt)
                    if frozen > 9 {
                        // Still stuck — re-establish the stream at our position.
                        lastProgressAt = Date()
                        lastLoadAt = Date()
                        stallNudged = false
                        ensureJS(playId, startAt: t)
                    } else if frozen > 4, !stallNudged {
                        // A buffer stall often just needs a kick before a full reload.
                        stallNudged = true
                        js("window.__encore && __encore.play()")
                    }
                }
            }
            currentTime = t
            if let d = body["d"] as? Double, d > 0 { duration = d }
            // Count a personal play once the song has played past a threshold
            // (~30s, or 90% for short songs), once per load.
            if isPlaying, !playCountRecorded, let track = current, !track.isEpisode {
                let threshold = duration > 0 ? min(30, duration * 0.9) : 30
                if t >= threshold {
                    playCountRecorded = true
                    PlayCounts.record(track)
                }
            }
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
        return vid == activePlaybackId
    }

    /// The videoId actually loaded in the web player — the audio counterpart for
    /// a music video, otherwise the current track's own id.
    private var activePlaybackId: String? { playingVideoId ?? current?.videoId }

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
        // Safety net: some apps end an interruption without sending the `.ended`
        // event, leaving us paused. If the user still wants playback, recover
        // when they come back to Encore.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.resumeIfIntended() }
        }
    }

    private func resumeIfIntended() {
        guard userWantsPlayback, !isPlaying, !sleepStopActive, current != nil else { return }
        forceResumePlayback()
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            // The system has paused our audio; mirror it in our state but DON'T
            // clear the playback intent — we still want to resume afterward.
            // Release the keep-alive so we don't fight the interrupter.
            stopKeepAlive()
            if isPlaying {
                js("window.__encore && __encore.pause()")
                isPlaying = false
                updateNowPlayingInfo()
            }
        } else {
            // Resume if the user still wants playback. Keying off intent (not the
            // momentary paused state) means rapid back-to-back interruptions —
            // e.g. scrolling past several sound-on Reels — still resume each time.
            // We also ignore `shouldResume`, which many interruptions don't set.
            _ = shouldResume
            guard userWantsPlayback, !sleepStopActive, current != nil else {
                // User-paused: keep the Now Playing widget alive so they can resume.
                if current != nil, !isPlaying, !sleepStopActive { startKeepAlive() }
                return
            }
            stopKeepAlive()
            forceResumePlayback()
        }
    }

    /// Resume the web player after an interruption. A plain `play()` often fails
    /// to restart the WKWebView's media element once the system has suspended it
    /// (notably after Siri) — so if playback hasn't picked up shortly, reload at
    /// the current position to force it back.
    private func forceResumePlayback() {
        try? AVAudioSession.sharedInstance().setActive(true)
        js("window.__encore && __encore.play()")
        resumeRetry(2)
    }

    /// After an interruption a plain `play()` often doesn't restart the web
    /// player's media element (notably after Siri). If we're still not playing
    /// shortly, fully reload the video at our position — which reliably restarts
    /// audio — and retry a couple of times in case the first reload doesn't take.
    private func resumeRetry(_ attemptsLeft: Int) {
        let canonicalId = current?.videoId
        let playId = activePlaybackId
        let pos = currentTime
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, !self.isPlaying, let canonicalId, let playId,
                  self.current?.videoId == canonicalId, !self.sleepStopActive else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.js("window.__encore && __encore.reload('\(playId)', \(pos))")
            if attemptsLeft > 1 { self.resumeRetry(attemptsLeft - 1) }
        }
    }

    // MARK: - Background keep-alive
    //
    // Playback runs in a WKWebView, which relinquishes the Now Playing slot when
    // its media element pauses — so after a paused stretch in the background iOS
    // drops the lock-screen / Control Center widget. To hold the slot the way a
    // native player does, we play looping silent audio while paused: the audio
    // session stays active, the widget stays, and the user can resume from it.

    private func startKeepAlive() {
        guard current != nil else { return }
        if keepAlivePlayer == nil {
            keepAlivePlayer = try? AVAudioPlayer(data: Self.silentLoopWAV)
            keepAlivePlayer?.numberOfLoops = -1
            keepAlivePlayer?.prepareToPlay()
        }
        guard let player = keepAlivePlayer, !player.isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    private func stopKeepAlive() {
        guard let player = keepAlivePlayer, player.isPlaying else { return }
        player.pause()
    }

    /// One second of 16-bit PCM silence in a WAV container, looped to hold the
    /// audio session active while paused.
    private static let silentLoopWAV: Data = {
        let sampleRate = 8000, seconds = 1, channels = 1, bitsPerSample = 16
        let dataSize = sampleRate * seconds * channels * bitsPerSample / 8
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(dataSize)
        d.append(Data(count: dataSize)) // zero samples = silence
        return d
    }()

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

      // Lock-screen / Control Center metadata is driven by the page's
      // MediaSession. Because we drive playback via loadVideoById, the site's
      // own metadata can lag the track we loaded (it would show the previous
      // song's artwork). Assert OUR metadata and re-assert briefly so we win the
      // race against the site's update on each track change.
      var __encoreMeta = null;
      var __encoreMetaTimer = null;
      function applyEncoreMeta() {
        if (!__encoreMeta || !('mediaSession' in navigator)) return;
        try {
          navigator.mediaSession.metadata = new MediaMetadata({
            title: __encoreMeta.title || '',
            artist: __encoreMeta.artist || '',
            album: __encoreMeta.album || '',
            artwork: __encoreMeta.art ? [{ src: __encoreMeta.art, sizes: '544x544', type: 'image/jpeg' }] : []
          });
        } catch (e) {}
      }
      function reassertEncoreMeta() {
        if (__encoreMetaTimer) clearInterval(__encoreMetaTimer);
        var n = 0;
        __encoreMetaTimer = setInterval(function () {
          applyEncoreMeta();
          if (++n >= 10) { clearInterval(__encoreMetaTimer); __encoreMetaTimer = null; }
        }, 500);
      }

      window.__encore = {
        ensure: function (id, start, force) {
          start = start || 0;
          var attempt = function (n) {
            var p = mp();
            if (p && p.loadVideoById && p.getVideoData) {
              var cur = p.getVideoData().video_id;
              var willLoad = (force || cur !== id);
              send({ event: 'engage', cur: cur || '', id: id, force: !!force, action: willLoad ? 'load' : 'resume' });
              if (willLoad) {
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
        // Force a fresh media load at `start` — playVideo() alone often won't
        // restart audio after a system interruption (e.g. Siri).
        reload: function (id, start) {
          var p = mp();
          if (!p || !p.loadVideoById) return;
          if (start > 0) { p.loadVideoById({ videoId: id, startSeconds: start }); }
          else { p.loadVideoById(id); }
        },
        // The video is never shown, so pin it to the lowest resolution — saves
        // bandwidth for music-video tracks on weak cellular (audio streams
        // separately, so audio quality is unaffected). Best-effort: modern YT
        // may ignore quality hints, but it can't hurt.
        lowData: function () {
          var p = mp();
          if (!p) return;
          try { if (p.setPlaybackQualityRange) p.setPlaybackQualityRange('tiny', 'tiny'); } catch (e) {}
          try { if (p.setPlaybackQuality) p.setPlaybackQuality('tiny'); } catch (e) {}
        },
        seek: function (s) { var p = mp(); if (p) p.seekTo(s, true); },
        rate: function (r) { var p = mp(); if (p && p.setPlaybackRate) { try { p.setPlaybackRate(r); } catch (e) {} } },
        vol: function (v) {
          var p = mp();
          if (p) { p.setVolume(v); if (v > 0 && p.isMuted && p.isMuted()) p.unMute(); }
        },
        setMeta: function (m) { __encoreMeta = m; applyEncoreMeta(); reassertEncoreMeta(); }
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
