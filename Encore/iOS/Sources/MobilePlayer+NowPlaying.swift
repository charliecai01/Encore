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

    func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

}
