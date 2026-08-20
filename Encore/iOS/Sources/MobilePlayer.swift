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

    @Published var current: Track?
    @Published var queue: [Track] = []
    @Published var index: Int = 0
    /// playlistId the current queue was played from, if it's an editable
    /// playlist. Enables "Remove from playlist" on the now-playing screen.
    /// nil for albums, radio, library songs, and home-shelf playback.
    @Published var playlistContextId: String?
    @Published var isPlaying = false
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleOn = false
    @Published var likedIds: Set<String> = []
    @Published var showNowPlaying = false
    @Published var sleepTimer: SleepTimerMode = .off
    @Published var toast: String?
    /// Bumped when native artist names finish resolving. Surfaces that show a
    /// name but own no other changing state — the mini player, Now Playing —
    /// observe this engine, so publishing here is what makes them re-render;
    /// otherwise they keep the romanized name until the track changes.
    @Published var nameVersion = 0
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
    @Published var playbackRate: Double = 1.0 {
        didSet { UserDefaults.standard.set(playbackRate, forKey: "playbackRate") }
    }
    /// Podcast video: shows the web player's video full-bleed in the podcast
    /// Now Playing screen (the site hides everything else via injected CSS).
    @Published var videoMode = false {
        didSet { js("window.__encore && __encore.videoMode(\(videoMode ? "true" : "false"))") }
    }
    /// 10-band graphic EQ (Web Audio, in the page). Persisted + pushed on change.
    @Published var eqSettings: EQSettings = Equalizer.load() {
        didSet { Equalizer.save(eqSettings); applyEqualizer() }
    }

    let webView: WKWebView
    let clock = PlayerClock.shared

    // `private(set)` in the original single-file engine kept views from
    // writing these directly (they observe `clock`, not the engine, for
    // exactly this reason). Now that engine-internal writes happen from
    // MobilePlayer+Internals.swift too, the setter needs module access —
    // still nothing outside PlayerEngine's own files writes to either.
    var currentTime: Double = 0 {
        didSet { clock.currentTime = currentTime }
    }
    var duration: Double = 0 {
        didSet { clock.duration = duration }
    }

    var playerReady = false
    var unshuffledQueue: [Track]?
    var lyricsRequestId = 0
    var lastEpisodeSaveAt = Date.distantPast
    /// Last time ANY bridge message arrived. The page reports 4×/second while
    /// alive, so prolonged silence means its web content process was killed.
    var lastBridgeAt = Date()
    /// When reloadSite() last ran, so a reload that never reports `ready` can
    /// be retried instead of wedging playback until the app is restarted.
    var lastReloadAt = Date.distantPast
    var livenessTimer: Timer?
    /// Unplayable-track handling: skip once per load on a player error, and
    /// give up pulling the site back after a few failed re-engages.
    var unplayableSkipped = false
    var failedEngages = 0
    /// True between interruption .began and .ended — never fight the system
    /// for audio during a call/Siri.
    var audioInterrupted = false
    /// Bounded retries for re-playing an episode that iOS paused on lock.
    var backgroundResumeNudges = 0
    var lastResignAt = Date.distantPast
    /// The hidden 1×1 container in MobileRoot the web view normally lives in;
    /// the podcast video view borrows the web view and parks it back here.
    weak var parkContainer: UIView?
    /// The in-flight autoplay radio fetch, shared so a tail prefetch and the
    /// end-of-queue advance never race — advance awaits the same fetch.
    var radioFetchTask: Task<Bool, Never>?
    var advancingViaRadio = false
    /// videoIds appended by autoplay extensions — the removable tail when the
    /// Autoplay toggle turns off. User-queued songs are never in here.
    var autoplayTailIds: Set<String> = []
    /// Endless-radio cursor from the active radio. Autoplay continues the radio
    /// with this instead of re-seeding `RDAMVM…`, which returns the same songs
    /// each time and dead-ends after dedup. nil for finite, non-radio queues.
    var radioContinuation: String?
    var toastTask: Task<Void, Never>?
    var sleepTask: Task<Void, Never>?
    var sleepStopActive = false
    /// On a cold launch the real music.youtube.com session can auto-start the
    /// account's last track. Block any site-initiated playback until the user
    /// explicitly presses play.
    var suppressSiteAutoplay = true
    /// The user's playback intent — true while they want music playing. Unlike
    /// the momentary `isPlaying`, this survives interruptions (a phone call, a
    /// loud Instagram Reel), so we resume when each interruption ends — even
    /// through rapid back-to-back interruptions where `isPlaying` is briefly
    /// false mid-recovery.
    var userWantsPlayback = false
    var lastLoadAt = Date.distantPast
    /// The track we're transitioning AWAY from, captured at the start of
    /// load(). Lets the hijack check tell a genuine site autoplay hijack
    /// (any other id) from a stale late report of the outgoing track, which
    /// still deserves the 0.5s grace.
    var previousVideoId: String?
    var mismatchTicks = 0
    var loadedOnce = false
    /// Force the next web-player engage to do a clean loadVideoById rather than
    /// resuming whatever the site auto-loaded. Set for the first play after a
    /// restored session, so we don't inherit the site's auto-resumed track and
    /// its radio "Up Next" (which would override our restored queue).
    var forceReloadOnEngage = false
    var restoreSeekTime: Double?
    var lastTimePersist = Date.distantPast
    /// The videoId actually loaded in the web player. Equals the current track's
    /// id for songs/episodes; for a music video it's the audio counterpart we
    /// swap in (iOS suspends WKWebView video in the background, so we play audio).
    /// Site state/time reports are matched against this, not the track's own id.
    var playingVideoId: String?
    /// Cache of resolved playback ids (audio counterpart, or the id itself when
    /// there's none) so replaying a music video skips the lookup.
    var resolvedPlaybackId: [String: String] = [:]
    // Stall watchdog: the furthest playback position we've seen and when, used to
    // detect a frozen stream (weak cellular) and re-establish it.
    var lastProgressT = 0.0
    var lastProgressAt = Date.distantPast
    var stallNudged = false
    /// The player reports it is buffering (YT state 3) — i.e. it IS making
    /// progress on a slow link. StallPolicy uses this to avoid reloading the
    /// download out from under itself.
    var isBuffering = false
    /// Stall reloads since the position last actually advanced. Drives the
    /// backoff so a bad link isn't hammered every few seconds.
    var consecutiveStallReloads = 0
    /// Guards one play-count increment per track load (recorded after a threshold).
    var playCountRecorded = false
    // Silent looping player that holds the audio session (and the Now Playing
    // slot) while paused — see the keep-alive section.
    var keepAlivePlayer: AVAudioPlayer?
    /// Cached artwork for the lock-screen/Control Center Now Playing info,
    /// set by MobilePlayer+NowPlaying.swift. Extensions can't declare stored
    /// properties, so it lives here with the rest of PlayerEngine's state.
    var artworkCache: (videoId: String, artwork: MPMediaItemArtwork)?

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
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        setupRemoteCommands()
        setupInterruptionHandling()
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

    // MARK: - Session persistence (same keys as the Mac app)

    private struct Snapshot: Codable {
        var queue: [Track]
        var unshuffled: [Track]?
        var index: Int
        var shuffle: Bool
        var repeatRaw: Int
        /// The playlist the queue was played from, so "Remove from Playlist"
        /// still works after a relaunch. Optional so older snapshots decode.
        var playlistId: String?
    }

    func persistSnapshot() {
        guard !queue.isEmpty else { return }
        let snapshot = Snapshot(queue: Array(queue.prefix(300)),
                                unshuffled: unshuffledQueue.map { Array($0.prefix(300)) },
                                index: min(index, 299),
                                shuffle: shuffleOn,
                                repeatRaw: repeatMode.rawValue,
                                playlistId: playlistContextId)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "playerSnapshot")
        }
        persistTime()
    }

    func persistTime() {
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
        playlistContextId = snapshot.playlistId
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

    func playCollection(_ tracks: [Track], startAt: Int, playlistId: String? = nil) {
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
        playlistContextId = playlistId
        radioContinuation = nil // finite context; radio is seeded fresh when it ends
        autoplayTailIds = []
        queue = playable
        index = start
        load(playable[start])
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

    /// Return the shared web view to its hidden 1×1 park in MobileRoot after
    /// the podcast video view borrowed it. Keeping it parented keeps WebKit
    /// from throttling audio.
    func parkWebView() {
        guard let park = parkContainer, webView.superview !== park else { return }
        webView.removeFromSuperview()
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        park.addSubview(webView)
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
        // Songs always run at 1× (engageJS and the state handler enforce it);
        // this guard is what keeps a speed tap from ever touching a song.
        if current?.isEpisode == true {
            js("window.__encore && __encore.rate(\(rate))")
        }
    }

}
