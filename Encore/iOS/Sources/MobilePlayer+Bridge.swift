import SwiftUI
import WebKit
import MediaPlayer
import AVFoundation
import EncoreCore

// JS bridge message handling — state/time reports from the injected controller.
extension PlayerEngine {
    // MARK: - Bridge events

    /// `fileprivate` in the original single-file engine — `BridgeHandler`
    /// (the WKScriptMessageHandler) lived in the same file and needed this.
    /// Now BridgeHandler is in MobilePlayer+Scripts.swift, so this needs
    /// module-internal access to stay callable from there.
    func handleBridge(_ body: [String: Any]) {
        lastBridgeAt = Date()   // proof the page is alive (see checkPageLiveness)
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
            applyEqualizer()
            if loadedOnce, let track = current {
                // Re-engage at where we actually were: a recovery reload mid-song
                // used to hand back startAt 0 and restart the track.
                startPlayback(track, startAt: restoreSeekTime ?? currentTime)
            }
        case "engage":
            // Diagnostic: what the web player already had loaded (the site's
            // auto-resumed session) vs. the track we asked for, and whether we
            // forced a clean load. This is the smoking gun for restore-then-play.
            Log.player.notice("engage: site cur=\(body["cur"] as? String ?? "nil") want=\(body["id"] as? String ?? "nil") force=\(body["force"] as? Bool ?? false) -> \(body["action"] as? String ?? "?")")
        case "videoDebug":
            // Fired ~2.5s after videoMode(true): videoWidth 0 means the stream
            // has no decoded video track; inline=0 means playsinline is missing.
            Log.player.notice("videoDebug: videos=\(body["n"] as? Int ?? -1) size=\(body["w"] as? Int ?? -1)x\(body["h"] as? Int ?? -1) readyState=\(body["rs"] as? Int ?? -1) paused=\(body["paused"] as? Int ?? -1) inline=\(body["inline"] as? Int ?? -1) desktopDOM=\(body["app"] as? Int ?? -1)")
        case "hijack":
            // The site's own autoplay overrode our load; the page re-asserted.
            Log.player.notice("hijack: site loaded \(body["cur"] as? String ?? "nil") over \(body["id"] as? String ?? "nil") — re-asserting")
        case "error":
            // The loaded video is unplayable (deleted/region-blocked) — skip it
            // instead of reload-looping while the site's queue bleeds through.
            let errVid = body["vid"] as? String
            Log.player.notice("player error code=\(body["code"] as? Int ?? -1) vid=\(errVid ?? "nil") current=\(self.current?.videoId ?? "nil")")
            if let track = current, !unplayableSkipped, !sleepStopActive,
               errVid == nil || errVid == activePlaybackId || errVid == track.videoId {
                unplayableSkipped = true
                showToast("Skipped unavailable: \(track.title)")
                advance(manual: true)
            }
        case "state":
            let state = body["data"] as? Int ?? -1
            isBuffering = (state == 3)
            Log.player.notice("state=\(state) vid=\(body["vid"] as? String ?? "nil") current=\(self.current?.videoId ?? "nil") suppress=\(self.suppressSiteAutoplay)")
            switch state {
            case 1:
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
                   let playId = activePlaybackId {
                    Log.player.notice("site autoplay started \(body["vid"] as? String ?? "?") over \(playId) — silencing and re-asserting")
                    js("window.__encore && __encore.pause()")
                    isPlaying = false
                    lastLoadAt = Date()
                    ensureJS(playId, startAt: currentTime)
                    break
                }
                isPlaying = true
                stopKeepAlive() // real audio is playing now
                backgroundResumeNudges = 0 // lock-pause recovery succeeded/reset
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
                if let track = current, track.isEpisode {
                    EpisodeProgress.save(track.videoId, position: currentTime, duration: duration)
                }
                // iOS suspends WKWebView VIDEO the moment the screen locks, and
                // podcast episodes are video streams with NO audio counterpart
                // (probed live 2026-07-05) — so locking/backgrounding pauses
                // them. If the user still wants playback and this isn't an
                // explicit pause or a call/Siri interruption, kick the element
                // back into play: WebKit resumes it AUDIO-ONLY in background.
                if let track = current, track.isEpisode,
                   userWantsPlayback, !sleepStopActive, !audioInterrupted,
                   UIApplication.shared.applicationState != .active
                       || Date().timeIntervalSince(lastResignAt) < 3,
                   backgroundResumeNudges < 6 {
                    backgroundResumeNudges += 1
                    Log.player.notice("episode paused in background — nudge #\(self.backgroundResumeNudges)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self, self.userWantsPlayback, !self.audioInterrupted,
                              self.current?.isEpisode == true, !self.isPlaying else { return }
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.js("window.__encore && __encore.play()")
                    }
                }
            case 0:
                isPlaying = false
                // Only advance on a *trustworthy* end-of-song. The page can briefly
                // report ENDED with a missing/blank video id during ads or buffering
                // glitches — those used to skip the song ~10s in. Require either a
                // confirmed video-id match or that we're genuinely near the end.
                let endedVid = body["vid"] as? String
                let confirmedEnd = !(endedVid ?? "").isEmpty && endedVid == activePlaybackId
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
                mismatchTicks += 1
                // Never re-engage while the sleep stop is active — ensure()'s
                // loadVideoById AUTOPLAYS, which resumed music after the timer
                // (and the failed-engage skip could then walk the queue).
                if mismatchTicks > 8, !suppressSiteAutoplay, !sleepStopActive, let playId = activePlaybackId {
                    mismatchTicks = 0
                    // A track that never takes after repeated pulls is
                    // unplayable — skip it rather than yank forever (the user
                    // hears fragments of the site's own queue otherwise).
                    failedEngages += 1
                    if failedEngages >= 3 {
                        failedEngages = 0
                        Log.player.notice("won't engage after repeated pulls — skipping '\(self.current?.title ?? "")'")
                        showToast("Skipped unavailable: \(current?.title ?? "song")")
                        advance(manual: true)
                        return
                    }
                    lastLoadAt = Date()
                    // Re-sync at our tracked position, not 0, so a glitch doesn't restart the song.
                    ensureJS(playId, startAt: currentTime)
                }
                return
            }
            mismatchTicks = 0
            if reportedMatchesCurrent(body) { failedEngages = 0 }
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
                    consecutiveStallReloads = 0
                } else if Date().timeIntervalSince(lastLoadAt) > 5, let playId = activePlaybackId {
                    let frozen = Date().timeIntervalSince(lastProgressAt)
                    switch StallPolicy.action(frozen: frozen,
                                              buffering: isBuffering,
                                              consecutiveReloads: consecutiveStallReloads,
                                              alreadyNudged: stallNudged) {
                    case .reload:
                        // Re-establish the stream at our position. Costs the
                        // buffer, so StallPolicy backs off after each one.
                        consecutiveStallReloads += 1
                        Log.player.notice("stall reload #\(self.consecutiveStallReloads) after \(Int(frozen))s frozen (buffering=\(self.isBuffering))")
                        lastProgressAt = Date()
                        lastLoadAt = Date()
                        stallNudged = false
                        ensureJS(playId, startAt: t)
                    case .nudge:
                        // A buffer stall often just needs a kick before a full reload.
                        stallNudged = true
                        js("window.__encore && __encore.play()")
                    case .none:
                        break
                    }
                }
            }
            currentTime = t
            if let d = body["d"] as? Double, d > 0 { duration = d }
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
        return vid == activePlaybackId
    }

    /// The videoId actually loaded in the web player — the audio counterpart for
    /// a music video, otherwise the current track's own id.
    var activePlaybackId: String? { playingVideoId ?? current?.videoId }

}
