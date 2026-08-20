import SwiftUI
import WebKit
import MediaPlayer
import AVFoundation
import EncoreCore

// Web view liveness, sleep timer, and the engine's own internal machinery.
extension PlayerEngine {
    // MARK: - Web view liveness

    /// iOS jettisons WKWebView content processes under memory pressure — a
    /// hidden 1×1 web view in a backgrounded app is a prime candidate. When
    /// that happens `window.__encore` is gone, every js() call silently does
    /// nothing, and NO bridge messages arrive — so the stall watchdog (which
    /// is driven BY those messages) can't fire either. The engine still
    /// believes the player is ready, so nothing plays until the app is
    /// relaunched. These two checks recover it in place.
    func startLivenessWatch() {
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPageLiveness() }
        }
    }

    func checkPageLiveness() {
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

    /// Push the current EQ settings into the page's Web Audio graph. No-op
    /// while the feature is off: calling eq() at all would tap the <video>
    /// element, which silences every track after the first (see Equalizer).
    func applyEqualizer() {
        guard Equalizer.featureEnabled else { return }
        js("window.__encore && __encore.eq(\(Equalizer.jsPayload(eqSettings)))")
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
        Task { try? await YTM.shared.setLiked(videoId: track.videoId, liked: !liked) }
    }

    /// Rebuild the page (sign-in change, or recovery from a dead web content
    /// process). Queue/index/current are untouched; `ready` re-engages the
    /// current track, still paused.
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
        // Stand down the engagement machinery: with the stop active, the
        // mismatch/error recovery paths must not pull the player back.
        mismatchTicks = 0
        failedEngages = 0
        js("window.__encore && __encore.pause()")
        isPlaying = false
        Log.player.notice("sleep timer fired — playback stopped")
        updateNowPlayingInfo()
        showToast("Sleep timer — paused. Good night ♪")
    }

    func sleepTimerConsumedSong() -> Bool {
        guard case .songs(let remaining) = sleepTimer else { return false }
        if remaining <= 1 {
            fireSleepTimer()
            return true
        }
        sleepTimer = .songs(remaining - 1)
        return false
    }

    // MARK: - Internals

    func load(_ track: Track, startAt: Double = 0) {
        loadedOnce = true
        userWantsPlayback = true // loading a track is an intent to play
        stopKeepAlive() // a real track is about to play
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
        // Video mode is a podcast-screen thing; never carry it onto songs.
        if videoMode, !track.isEpisode { videoMode = false }
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
        unplayableSkipped = false
        failedEngages = 0
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
    func startPlayback(_ track: Track, startAt: Double) {
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
    func engageJS(_ videoId: String, track: Track, startAt: Double) {
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
    func ensureJS(_ videoId: String, startAt: Double) {
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

    func advance(manual: Bool = false) {
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
    /// `explicit` = the user just flipped the toggle: fetch even under repeat.
    /// Silent (like the site) — appended songs just show up at the queue tail.
    func prefetchAutoplayTail(explicit: Bool = false) {
        guard autoplayEnabled, !queue.isEmpty, explicit || repeatMode == .off else { return }
        Log.player.notice("autoplay: prefetching radio tail (explicit=\(explicit), hasContinuation=\(self.radioContinuation != nil))")
        ensureRadioFetch()
    }

    /// Strip not-yet-played autoplay tracks from the queue — the site's
    /// behavior when the Autoplay toggle turns off. Rows at or before the
    /// current index stay (already played / playing); the user's own songs
    /// are never touched.
    func removeAutoplayTail() {
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

    func updateLyricIndex() {
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

    func js(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

}
