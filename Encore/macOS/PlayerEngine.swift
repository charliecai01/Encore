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
        didSet {
            UserDefaults.standard.set(autoplayEnabled, forKey: "autoplayEnabled")
            // Mirror the site's toggle: ON populates the queue tail right
            // away; OFF strips the not-yet-played autoplay tracks so the
            // queue returns to just your own songs.
            if autoplayEnabled && !oldValue { prefetchAutoplayTail(explicit: true) }
            if !autoplayEnabled && oldValue { removeAutoplayTail() }
        }
    }
    @Published var toast: String?
    @Published var videoMode = false {
        didSet { js("window.__encore && __encore.videoMode(\(videoMode ? "true" : "false"))") }
    }
    /// Podcast playback speed — applies to episodes only; songs always play 1×.
    @Published var playbackRate: Double = 1.0 {
        didSet { UserDefaults.standard.set(playbackRate, forKey: "playbackRate") }
    }
    /// 10-band graphic EQ (Web Audio, in the page). Persisted + pushed on change.
    @Published var eqSettings: EQSettings = Equalizer.load() {
        didSet { Equalizer.save(eqSettings); applyEqualizer() }
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
    private var lastEpisodeSaveAt = Date.distantPast
    /// Last time ANY bridge message arrived. The page reports 4x/second while
    /// alive, so prolonged silence means its web content process was killed.
    private var lastBridgeAt = Date()
    /// When reloadSite() last ran, so a reload that never reports `ready` can
    /// be retried instead of wedging playback until the app is restarted.
    private var lastReloadAt = Date.distantPast
    private var livenessTimer: Timer?
    /// Unplayable-track handling: skip once per load on a player error, and
    /// give up pulling the site back after a few failed re-engages.
    private var unplayableSkipped = false
    private var failedEngages = 0
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
    // When the sleep timer fires we must keep playback stopped even though
    // music.youtube.com may try to autoplay the next track on its own.
    private var sleepStopActive = false
    // On a cold launch the music.youtube.com session can auto-start the account's
    // last track on its own (the app starts "playing randomly"). Suppress any
    // site-initiated playback until the user explicitly plays something.
    private var suppressSiteAutoplay = true
    private var lastLoadAt = Date.distantPast
    private var mismatchTicks = 0
    /// Guards one play-count increment per track load (recorded after a threshold).
    private var playCountRecorded = false
    private var loadedOnce = false
    /// Force the next web-player engage to do a clean loadVideoById rather than
    /// resuming whatever the site auto-loaded. Set for the first play after a
    /// restored session, so we don't inherit the site's auto-resumed track and
    /// its radio "Up Next" (which would override our restored queue).
    private var forceReloadOnEngage = false
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
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        setupRemoteCommands()
        startLivenessWatch()
        if UserDefaults.standard.object(forKey: "autoplayEnabled") != nil {
            autoplayEnabled = UserDefaults.standard.bool(forKey: "autoplayEnabled")
        }
        if UserDefaults.standard.object(forKey: "playbackRate") != nil {
            let r = UserDefaults.standard.double(forKey: "playbackRate")
            if r > 0 { playbackRate = r }
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

        // Restore the queue and the current track. Songs restart from the
        // beginning on reopen (by design); podcast EPISODES resume where you
        // left off, like Apple Podcasts — load() only covers row taps, so the
        // restored-session path needs its own resume here.
        duration = Double(current?.durationSeconds ?? 0)
        currentTime = 0
        restoreSeekTime = nil
        if let cur = current, cur.isEpisode,
           let resume = EpisodeProgress.resumePosition(for: cur.videoId) {
            currentTime = resume
            restoreSeekTime = resume
        }
        Log.player.notice("restore: \(snapshot.queue.count) tracks, index=\(self.index), current=\(self.current?.videoId ?? "nil") '\(self.current?.title ?? "")' resumeAt=\(self.restoreSeekTime ?? 0)")
        updateNowPlayingInfo()
    }

    // MARK: - Public playback API

    func playCollection(_ tracks: [Track], startAt: Int) {
        guard !tracks.isEmpty, startAt < tracks.count else { return }
        // Keep YouTube's greyed-out tracks out of the queue entirely, so
        // auto-advance never walks into a run of them (error 150 → skip, over
        // and over, which reads as the player jumping around).
        let (playable, start) = PlayableQueue.build(tracks, startAt: startAt)
        guard !playable.isEmpty else {
            showToast("Nothing here is available on YouTube Music")
            return
        }
        unshuffledQueue = nil
        shuffleOn = false
        radioContinuation = nil // finite context; radio is seeded fresh when it ends
        autoplayTailIds = []
        queue = playable
        index = start
        load(playable[start])
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        unshuffledQueue = tracks
        shuffleOn = true
        radioContinuation = nil
        autoplayTailIds = []
        queue = tracks.shuffled()
        index = 0
        load(queue[0])
    }

    /// Play a track immediately and grow a radio queue behind it.
    func playRadio(from track: Track) {
        // Episode "radio" (RDAMVM<episodeId>) is not a real thing on YT Music —
        // the returned queue is junk whose items die after a few seconds,
        // cascading ended→advance so fast that pause can't stick. Just play
        // the episode.
        if track.isEpisode {
            playCollection([track], startAt: 0)
            return
        }
        unshuffledQueue = nil
        shuffleOn = false
        radioContinuation = nil
        autoplayTailIds = []
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
        if queue.isEmpty || current == nil {
            playRadio(from: track)
            return
        }
        autoplayTailIds.remove(track.videoId) // explicitly queued = user's own
        queue.insert(track, at: min(index + 1, queue.count))
        showToast("Playing next: \(track.title)")
        persistSnapshot()
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty || current == nil {
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
        suppressSiteAutoplay = false // …and the launch autoplay guard
        // First play after a restored session: start the web player directly at
        // the saved offset (reliable) instead of seeking after it begins at 0.
        if !loadedOnce {
            // Force a clean load so the first play after a restored session
            // replaces the site's auto-resumed track (and its radio queue) with
            // our restored queue, instead of resuming the site's own session.
            Log.player.notice("firstPlay(restored): current=\(track.videoId) '\(track.title)', forcing clean load")
            forceReloadOnEngage = true
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

    /// Fold authoritative per-row thumbs-up state into `likedIds`. Tracks whose
    /// payload didn't say are left alone, so a page that omits likeStatus can't
    /// wipe state we already know.
    func reconcileLikes(from tracks: [Track]) {
        for track in tracks {
            guard let liked = track.isLiked else { continue }
            if liked { likedIds.insert(track.videoId) } else { likedIds.remove(track.videoId) }
        }
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
        // Stand down the engagement machinery: with the stop active, the
        // mismatch/error recovery paths must not pull the player back.
        mismatchTicks = 0
        failedEngages = 0
        js("window.__encore && __encore.pause()")
        isPlaying = false
        updateNowPlayingInfo()
        Log.player.notice("sleep timer fired — playback stopped")
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

    /// WebKit can kill the web view's content process (memory pressure). Then
    /// `window.__encore` is gone, every js() call silently no-ops, and NO
    /// bridge messages arrive — so the stall watchdog, which is driven BY those
    /// messages, can't fire either. Nothing plays until the app restarts.
    private func startLivenessWatch() {
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPageLiveness() }
        }
    }

    private func checkPageLiveness() {
        switch PageLiveness.action(playerReady: playerReady,
                                   sinceLastBridge: Date().timeIntervalSince(lastBridgeAt),
                                   sinceLastReload: Date().timeIntervalSince(lastReloadAt)) {
        case .none:
            return
        case .reloadDeadPage:
            Log.player.error("no bridge messages for \(Int(PageLiveness.deadAfter))s — page is dead; reloading site")
            reloadSite()
        case .retryFailedReload:
            // Without this the engine stays un-ready forever: load()'s engage is
            // gated on playerReady, so every track falls back to the slow
            // mismatch recovery and only an app restart fixes it.
            Log.player.error("reload never became ready after \(Int(Date().timeIntervalSince(lastReloadAt)))s — reloading site again")
            reloadSite()
        }
    }

    /// Reload the hidden site after the session changes (sign-in/out) or to
    /// recover a dead web content process.
    func reloadSite() {
        playerReady = false
        lastBridgeAt = Date()   // grace period while the reload runs
        lastReloadAt = Date()   // so a reload that never becomes ready is retried
        // A rebuilt page auto-resumes the ACCOUNT's last track, and `ready`
        // re-engages ours — either one would start audio the user never asked
        // for when the process died while paused. Re-arm the launch guard so
        // the state-1 handler force-pauses whatever starts; playing sessions
        // keep it off so they resume normally.
        suppressSiteAutoplay = !isPlaying
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
        // Leaving an episode midway: remember the spot so it resumes later.
        if let prev = current, prev.isEpisode, prev.videoId != track.videoId {
            EpisodeProgress.save(prev.videoId, position: currentTime, duration: duration)
        }
        // Episodes resume where you left off (Apple-Podcasts style).
        var startAt = startAt
        if startAt == 0, track.isEpisode,
           let resume = EpisodeProgress.resumePosition(for: track.videoId) {
            startAt = resume
        }
        // Carry the resume offset so the ready/state handlers can apply it too.
        restoreSeekTime = startAt > 0 ? startAt : nil
        sleepStopActive = false
        suppressSiteAutoplay = false // explicit user intent overrides the launch guard
        current = track
        currentTime = startAt
        duration = Double(track.durationSeconds ?? 0)
        clock.lyrics = nil
        clock.currentLyricIndex = nil
        lastLoadAt = Date()
        mismatchTicks = 0
        playCountRecorded = false
        unplayableSkipped = false
        failedEngages = 0
        persistSnapshot()

        if playerReady {
            ensureJS(track.videoId, startAt: startAt)
            // Episodes keep the chosen speed; songs are forced back to 1×.
            js("window.__encore && __encore.rate(\(track.isEpisode ? playbackRate : 1.0))")
        }

        updateNowPlayingInfo()
        fetchLyrics(for: track)
    }

    /// Load/resume a video in the web player, optionally from `startAt` seconds.
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
        // Queue exhausted: keep the music going with radio based on the last track.
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
    /// `explicit` = the user just flipped the toggle: fetch even under repeat.
    /// Silent (like the site) — appended songs just show up at the queue tail.
    private func prefetchAutoplayTail(explicit: Bool = false) {
        guard autoplayEnabled, !queue.isEmpty, explicit || repeatMode == .off else { return }
        Log.player.notice("autoplay: prefetching radio tail (explicit=\(explicit), hasContinuation=\(self.radioContinuation != nil))")
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
        // Never seed a radio from an episode (junk queue); episode queues
        // simply end, like Apple Podcasts.
        guard let last = queue.last, !last.isEpisode else { return false }
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
        // A page can dedupe to nothing (e.g. re-seeding a radio whose songs
        // are already queued) while merge still advances the cursor — keep
        // following it instead of giving up on the first empty page. One
        // fresh seed is allowed when there's no cursor or it dead-ends.
        var seeded = false
        for _ in 0..<5 {
            guard autoplayEnabled else { return false }
            if let token = radioContinuation {
                if merge(try? await YTM.shared.queueContinuation(token)) { return true }
                if radioContinuation != token { continue } // all-dupe page: follow the next
                radioContinuation = nil                    // cursor dead — reseed below
            }
            if seeded { return false }
            seeded = true
            if merge(try? await YTM.shared.radioQueue(for: last.videoId)) { return true }
            if radioContinuation == nil { return false }   // seed gave no cursor either
        }
        return false
    }

    /// Skip forward/back by a number of seconds (podcast controls).
    func skip(_ delta: Double) {
        let target = currentTime + delta
        let upper = duration > 0 ? duration : target
        seek(to: max(0, min(target, upper)))
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        // Rate is a podcast concept — apply live only while an episode plays.
        if current?.isEpisode == true {
            js("window.__encore && __encore.rate(\(rate))")
        }
    }

    /// Push the current EQ settings into the page's Web Audio graph. No-op
    /// while the feature is off: calling eq() at all would tap the <video>
    /// element, which silences every track after the first (see Equalizer).
    func applyEqualizer() {
        guard Equalizer.featureEnabled else { return }
        js("window.__encore && __encore.eq(\(Equalizer.jsPayload(eqSettings)))")
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
        lastBridgeAt = Date()   // proof the page is alive (see checkPageLiveness)
        guard let event = body["event"] as? String else { return }
        switch event {
        case "ready":
            // Fires on every page load of the hidden web view. Only re-engage
            // the player if playback already started this session — a restored
            // session must stay paused until the user hits play.
            playerReady = true
            Log.player.notice("ready: loadedOnce=\(self.loadedOnce) current=\(self.current?.videoId ?? "nil")")
            js("window.__encore && __encore.vol(\(Int(volume * 100)))")
            applyEqualizer()
            if loadedOnce, let track = current {
                // Re-engage at where we actually were: a recovery reload mid-song
                // used to hand back startAt 0 and restart the track.
                ensureJS(track.videoId, startAt: restoreSeekTime ?? currentTime)
            }
        case "engage":
            // Diagnostic: what the web player already had loaded (the site's
            // auto-resumed session) vs. the track we asked for, and whether we
            // forced a clean load. The smoking gun for restore-then-play.
            Log.player.notice("engage: site cur=\(body["cur"] as? String ?? "nil") want=\(body["id"] as? String ?? "nil") force=\(body["force"] as? Bool ?? false) -> \(body["action"] as? String ?? "?")")
        case "hijack":
            // The site's own autoplay overrode our load; the page re-asserted.
            Log.player.notice("hijack: site loaded \(body["cur"] as? String ?? "nil") over \(body["id"] as? String ?? "nil") — re-asserting")
        case "error":
            // The loaded video is unplayable (deleted/region-blocked) — skip it
            // instead of reload-looping while the site's queue bleeds through.
            let errVid = body["vid"] as? String
            Log.player.notice("player error code=\(body["code"] as? Int ?? -1) vid=\(errVid ?? "nil") current=\(self.current?.videoId ?? "nil")")
            if let track = current, !unplayableSkipped, !sleepStopActive,
               errVid == nil || errVid == track.videoId {
                unplayableSkipped = true
                showToast("Skipped unavailable: \(track.title)")
                advance(manual: true)
            }
        case "state":
            let state = body["data"] as? Int ?? -1
            Log.player.notice("state=\(state) vid=\(body["vid"] as? String ?? "nil") current=\(self.current?.videoId ?? "nil") suppress=\(self.suppressSiteAutoplay)")
            switch state {
            case 1:
                // The sleep timer fired, or the site auto-started a track on
                // launch before the user pressed play — force it back to paused.
                if sleepStopActive || suppressSiteAutoplay {
                    js("window.__encore && __encore.pause()")
                    isPlaying = false
                    break
                }
                // The site queues ITS OWN next track at a transition and can win
                // the race to start playing. Never accept audio that isn't ours:
                // silence it and re-assert now. The mismatch recovery in the
                // `time` handler only acts after 6s of grace plus 8 ticks, which
                // is long enough to hear a chunk of a song nobody queued — the
                // "plays something random for a few seconds" report.
                if !reportedMatchesCurrent(body),
                   Date().timeIntervalSince(lastLoadAt) > 0.5,
                   let track = current {
                    Log.player.notice("site autoplay started \(body["vid"] as? String ?? "?") over \(track.videoId) — silencing and re-asserting")
                    js("window.__encore && __encore.pause()")
                    isPlaying = false
                    lastLoadAt = Date()
                    ensureJS(track.videoId, startAt: currentTime)
                    break
                }
                isPlaying = true
                // Playback speed applies to podcast episodes only. Songs always
                // play at 1× — otherwise the web player carries an episode's
                // rate onto the next song for a few seconds before resetting.
                js("window.__encore && __encore.rate(\(current?.isEpisode == true ? playbackRate : 1.0))")
                if let resumeAt = restoreSeekTime {
                    restoreSeekTime = nil
                    seek(to: resumeAt)
                }
            case 2:
                isPlaying = false
                if let track = current, track.isEpisode {
                    EpisodeProgress.save(track.videoId, position: currentTime, duration: duration)
                }
            case 0:
                isPlaying = false
                // Only advance on a *trustworthy* end-of-song. The page can briefly
                // report ENDED with a missing/blank video id during ads or buffering
                // glitches — those used to skip the song early. Require either a
                // confirmed video-id match or that we're genuinely near the end.
                let endedVid = body["vid"] as? String
                let confirmedEnd = !(endedVid ?? "").isEmpty && endedVid == current?.videoId
                let nearEnd = duration > 0 && currentTime >= duration - 6
                if confirmedEnd || nearEnd, let track = current, track.isEpisode {
                    // Finished an episode: mark played, drop the resume point.
                    PlayedEpisodes.set(track.videoId, played: true)
                    EpisodeProgress.clear(track.videoId)
                }
                if (confirmedEnd || nearEnd), !sleepTimerConsumedSong() {
                    advance()
                }
            default:
                break
            }
            updateNowPlayingInfo()
        case "time":
            guard reportedMatchesCurrent(body) || Date().timeIntervalSince(lastLoadAt) < 6 else {
                // The site wandered off (its own autoplay); pull it back — but
                // not while we're suppressing launch autoplay, or we'd start the
                // restored track ourselves before the user asked to play.
                mismatchTicks += 1
                // Never re-engage while the sleep stop is active — ensure()'s
                // loadVideoById AUTOPLAYS, which resumed music after the timer
                // (and the failed-engage skip could then walk the queue).
                if mismatchTicks > 8, !suppressSiteAutoplay, !sleepStopActive, let track = current {
                    mismatchTicks = 0
                    // A track that never takes after repeated pulls is
                    // unplayable — skip it rather than yank forever (the user
                    // hears fragments of the site's own queue otherwise).
                    failedEngages += 1
                    if failedEngages >= 3 {
                        failedEngages = 0
                        Log.player.notice("won't engage after repeated pulls — skipping '\(self.current?.title ?? "")'")
                        showToast("Skipped unavailable: \(track.title)")
                        advance(manual: true)
                        return
                    }
                    lastLoadAt = Date()
                    // Re-sync at our tracked position, not 0, so a glitch doesn't restart the song.
                    ensureJS(track.videoId, startAt: currentTime)
                }
                return
            }
            mismatchTicks = 0
            if reportedMatchesCurrent(body) { failedEngages = 0 }
            let t = body["t"] as? Double ?? 0
            let d = body["d"] as? Double ?? 0
            currentTime = t
            if d > 0 { duration = d }
            // Remember episode positions every few seconds so force-quits and
            // crashes lose at most a moment of the resume point.
            if isPlaying, let track = current, track.isEpisode,
               Date().timeIntervalSince(lastEpisodeSaveAt) > 5 {
                lastEpisodeSaveAt = Date()
                EpisodeProgress.save(track.videoId, position: t, duration: duration)
            }
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
        return vid == current?.videoId
    }

    // MARK: - System now playing

    private var artworkCache: (videoId: String, artwork: MPMediaItemArtwork)?

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Play/pause must set an explicit state, not toggle: macOS fires
        // pauseCommand whenever another app grabs "now playing" or the audio
        // route changes (AirPods connect/disconnect, an earbud removed, a
        // browser video starts). Routed through togglePlay(), a pause arriving
        // while already paused flipped Encore into *playing* — the app
        // "randomly" starting on its own. Only act toward the requested state.
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isPlaying else { return }
                self.togglePlay()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying else { return }
                self.togglePlay()
            }
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

      // --- 10-band graphic EQ (Web Audio biquad filters) ---
      // Tap the <video> element with a MediaElementSource, run it through ten
      // peaking filters + a preamp gain, out to the destination. Built lazily
      // only once EQ is enabled, so users who never touch it keep the untouched
      // audio path. createMediaElementSource is once-per-element, so we track
      // the element and rebuild if the site swaps it.
      var EQ_FREQS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
      var eqCtx = null, eqSrc = null, eqEl = null, eqBands = [], eqPre = null;
      var eqOn = false, eqGains = [0,0,0,0,0,0,0,0,0,0], eqPreDb = 0;
      function eqBuild() {
        var v = document.querySelector('video');
        if (!v) return false;
        if (eqEl === v && eqCtx) return true;
        try {
          if (!eqCtx) eqCtx = new (window.AudioContext || window.webkitAudioContext)();
          eqSrc = eqCtx.createMediaElementSource(v);
          eqEl = v;
          eqBands = EQ_FREQS.map(function (f) {
            var b = eqCtx.createBiquadFilter();
            b.type = 'peaking'; b.frequency.value = f; b.Q.value = 1.41; b.gain.value = 0;
            return b;
          });
          eqPre = eqCtx.createGain(); eqPre.gain.value = 1;
          var node = eqSrc;
          eqBands.forEach(function (b) { node.connect(b); node = b; });
          node.connect(eqPre); eqPre.connect(eqCtx.destination);
          return true;
        } catch (e) { return false; }
      }
      function eqApply() {
        if (!eqCtx) return;
        if (eqCtx.state === 'suspended') { try { eqCtx.resume(); } catch (e) {} }
        for (var i = 0; i < eqBands.length; i++) {
          eqBands[i].gain.value = eqOn ? (eqGains[i] || 0) : 0;
        }
        if (eqPre) eqPre.gain.value = eqOn ? Math.pow(10, (eqPreDb || 0) / 20) : 1;
      }

      var videoModeStyle = null;
      // Bumped by every ensure() so an older load's watchdog can't fight a
      // newer one (e.g. the user pressing next while a watchdog is running).
      var encoreGen = 0;
      window.__encore = {
        eq: function (cfg) {
          try {
            eqOn = !!cfg.enabled;
            eqPreDb = cfg.preamp || 0;
            if (cfg.gains && cfg.gains.length) eqGains = cfg.gains;
          } catch (e) {}
          if (eqOn && !eqBuild()) return; // no <video> yet — the tick retries
          eqApply();
        },
        ensure: function (id, start, force) {
          start = start || 0;
          var gen = ++encoreGen;
          var attempt = function (n) {
            if (gen !== encoreGen) { return; }
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
              // Watchdog, for ~5s after a load. Two jobs:
              // 1. Nudge playVideo() if the player ends up CUED (5)/UNSTARTED (-1).
              // 2. RE-ASSERT our track if the site's own autoplay hijacks the
              //    load. When a song ends the site queues ITS next track and
              //    calls loadVideoById a beat after ours, so the user hears the
              //    wrong song until the slow mismatch recovery (6s grace + 2s
              //    of ticks) pulls it back. Correcting here makes that ~0.4s.
              var nudges = 0, reloads = 0, sawOurs = false;
              var nudge = function () {
                if (gen !== encoreGen) { return; } // superseded by a newer load
                var q = mp();
                if (!q || !q.getPlayerState || !q.getVideoData) { return; }
                var now = q.getVideoData().video_id;
                if (now === id) { sawOurs = true; }
                if (now && now !== id) {
                  // Only a HIJACK once our load has actually taken and the id
                  // then changed away. Before that the player is still
                  // committing our load, and reloading would restart it every
                  // 500ms — a loop that stops playback from ever starting.
                  if (sawOurs && reloads < 3) {
                    reloads++;
                    send({ event: 'hijack', cur: now, id: id });
                    if (start > 0) { q.loadVideoById({ videoId: id, startSeconds: start }); }
                    else { q.loadVideoById(id); }
                  }
                  if (++nudges < 10) { setTimeout(nudge, 500); }
                  return;
                }
                var s = q.getPlayerState();
                if (s === 5 || s === -1) { q.playVideo(); }
                if (++nudges < 10) { setTimeout(nudge, 500); }
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
          var p = mp();
          if (!p) return;
          try {
            if (on) {
              // Bump quality and re-negotiate at the current spot so the
              // player fetches segments WITH the video track (it may have
              // been decoding audio-only while parked).
              if (p.setPlaybackQualityRange) p.setPlaybackQualityRange('large', 'hd1080');
              if (p.setPlaybackQuality) p.setPlaybackQuality('large');
              if (p.seekTo && p.getCurrentTime) p.seekTo(p.getCurrentTime(), true);
            }
          } catch (e) {}
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
        // Unplayable videos (deleted/region-blocked) fire onError and never
        // reach a playing state — report so the engine can SKIP instead of
        // reload-looping while the site's own queue bleeds through.
        p.addEventListener('onError', function (code) {
          var data = p.getVideoData ? p.getVideoData() : null;
          send({ event: 'error', code: code, vid: data ? data.video_id : null });
        });
      }

      var lastState = -9;
      setInterval(function () {
        hookPlayer();
        if (eqOn && eqBuild()) eqApply(); // re-hook if the site swapped <video>
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

// MARK: - Web content process recovery

extension PlayerEngine: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.player.error("web content process TERMINATED — reloading site")
        reloadSite()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Log.player.error("site load failed: \(error.localizedDescription)")
    }
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
