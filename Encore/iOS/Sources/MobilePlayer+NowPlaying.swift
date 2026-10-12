import SwiftUI
import WebKit
import MediaPlayer
import AVFoundation
import EncoreCore

// Lock-screen/Control Center Now Playing, phone-call/Siri interruptions, and
// the background keep-alive silent player. `artworkCache` (used here) lives
// in the main PlayerEngine file — extensions can't declare stored properties.
extension PlayerEngine {
    // MARK: - Audio interruptions (phone calls, Siri, other apps)

    func setupInterruptionHandling() {
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
            DispatchQueue.main.async {
                self?.audioInterrupted = false
                self?.backgroundResumeNudges = 0
                // Timers don't fire while suspended, so the bridge legitimately
                // went quiet — restart the liveness window instead of reading
                // that silence as a dead page.
                self?.lastBridgeAt = Date()
                self?.resumeIfIntended()
            }
        }
        // Timestamp backgrounding/locking so the state-2 handler can tell a
        // lock-induced episode pause from a user pause even if the pause
        // event races the applicationState transition.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.lastResignAt = Date() }
        }
    }

    private func resumeIfIntended() {
        guard userWantsPlayback, !isPlaying, !sleepStopActive, current != nil else { return }
        forceResumePlayback()
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        // Another app (Instagram Reels, a call, Siri) took the audio session —
        // logged so a pause/resume in a capture can be attributed to it.
        Log.player.notice("audio interruption \(began ? "began" : "ended") shouldResume=\(shouldResume) wantsPlayback=\(self.userWantsPlayback)")
        audioInterrupted = began
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

    func startKeepAlive() {
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

    func stopKeepAlive() {
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

    func setupRemoteCommands() {
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

    func updateNowPlayingInfo() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            nowPlayingPublishedId = nil
            nowPlayingHold = nil
            return
        }
        configureRemoteCommands(forEpisode: track.isEpisode)
        if CarDebug.pageOnly {
            // Car-debug: native publishes nothing, so WebKit's MediaSession
            // (title + preloaded art in one update) is the only Now Playing.
            if MPNowPlayingInfoCenter.default().nowPlayingInfo != nil {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            // A stable id per track. Without it MediaRemote makes every write
            // (play, pause, buffering: ~3 per song) a NEW item, so a Bluetooth
            // head unit sees several track changes per song. This publisher is
            // the one the system shows (see HANDOFF §5).
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.videoId,
        ]
        if let album = track.album?.name {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if CarDebug.richIdentity {
            // Extra track-identity signals some AVRCP stacks key on.
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = max(queue.count, index + 1)
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            info[MPMediaItemPropertyPersistentID] = NSNumber(value: CarDebug.stableId(track.videoId))
        }
        if let cached = artworkCache, cached.videoId == track.videoId {
            info[MPMediaItemPropertyArtwork] = cached.artwork
        } else if track.artworkURL != nil, artworkFinishedId != track.videoId {
            // Don't publish the new title without its art: a Bluetooth head
            // unit asks for cover art when the track changes, gets none, and
            // never asks again (Tesla showed no art from the 2nd song on).
            // Publish once the image is in hand — title + art together.
            let id = track.videoId
            Task {
                await ensureArtwork(for: track)
                if current?.videoId == id { updateNowPlayingInfo() }
            }
            return
        }
        if CarDebug.publishDelay, nowPlayingPublishedId != track.videoId {
            // Hold the new track's first publish back ~0.7s (art is already in
            // hand), in case the car samples metadata too early on a change.
            let hold = nowPlayingHold
            if hold?.videoId != track.videoId {
                nowPlayingHold = (track.videoId, Date().addingTimeInterval(0.65))
                let id = track.videoId
                Log.player.notice("nowplaying: holding \(id) 700ms")
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if current?.videoId == id { updateNowPlayingInfo() }
                }
                return
            }
            if let until = hold?.until, Date() < until { return }
        }
        nowPlayingPublishedId = track.videoId
        // One line per write: what the system (and so the car) is being given.
        Log.player.notice("nowplaying: id=\(track.videoId) '\(track.title)' art=\(info[MPMediaItemPropertyArtwork] != nil ? "yes" : "no") rate=\(isPlaying ? 1 : 0) qi=\(index) car=\(CarDebug.summary)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Download the track's artwork once (joins an in-flight download) and cache
    /// it both natively and as a data: URI for the page's MediaSession.
    func ensureArtwork(for track: Track) async {
        guard track.artworkURL != nil else { return }
        if let t = artworkTask, t.videoId == track.videoId {
            await t.task.value
            return
        }
        let task = Task { await downloadArtwork(for: track) }
        artworkTask = (track.videoId, task)
        await task.value
    }

    private func downloadArtwork(for track: Track) async {
        defer { artworkFinishedId = track.videoId }
        guard let url = track.artworkURL else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let image = UIImage(data: data) else { return }
        artworkCache = (track.videoId, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
        artworkDataURI = (track.videoId, "data:image/jpeg;base64," + data.base64EncodedString())
    }

    func updateNowPlayingElapsed() {
        if CarDebug.pageOnly { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

}

/// Hidden switches for the in-car Bluetooth/Tesla cover-art experiments
/// (Account menu → Car debug). All default OFF = shipping behaviour. Each takes
/// effect on the next track change. See HANDOFF §5 (Bluetooth/car cover art).
enum CarDebug {
    static let pageOnlyKey = "carDebug.pageOnly"
    static let richIdentityKey = "carDebug.richIdentity"
    static let publishDelayKey = "carDebug.publishDelay"

    /// Native MPNowPlayingInfoCenter stays empty, so the page's MediaSession
    /// (WebKit) is the only Now Playing source the car can see. (Blanking the
    /// page's metadata instead does NOT work: WebKit still publishes an item
    /// built from the document title.)
    static var pageOnly: Bool { UserDefaults.standard.bool(forKey: pageOnlyKey) }
    /// Adds queue index/count, persistent id etc. to the native info.
    static var richIdentity: Bool { UserDefaults.standard.bool(forKey: richIdentityKey) }
    /// Holds each new track's native publish back ~700ms.
    static var publishDelay: Bool { UserDefaults.standard.bool(forKey: publishDelayKey) }

    static var summary: String {
        let on = [pageOnly ? "page-only" : nil,
                  richIdentity ? "rich-id" : nil,
                  publishDelay ? "delay" : nil].compactMap { $0 }
        return on.isEmpty ? "off" : on.joined(separator: "+")
    }

    /// Deterministic 64-bit id (FNV-1a) — Swift's Hasher is randomized per launch.
    static func stableId(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
