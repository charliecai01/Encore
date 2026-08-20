import SwiftUI
import WebKit
import MediaPlayer
import AVFoundation
import EncoreCore

// The injected JS controller payload.
extension PlayerEngine {
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
        // Own the metadata too: once Encore pushes track metadata, site writes
        // are IGNORED — the site updates its MediaMetadata late (slow metadata
        // fetches, SPA events mid-song), which used to overwrite our artwork on
        // the lock screen / Notification Center with the wrong track's art.
        try {
          var desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(ms), 'metadata');
          if (desc && desc.set) {
            Object.defineProperty(ms, 'metadata', {
              configurable: true,
              get: function () { return desc.get.call(ms); },
              set: function (v) {
                if (window.__encoreOwnsMeta) return;
                desc.set.call(ms, v);
              }
            });
            window.__encoreSetMetadata = function (v) { desc.set.call(ms, v); };
          }
        } catch (e) {}
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
      var videoModeStyle = null;
      // Bumped by every ensure() so an older load's watchdog can't fight a
      // newer one (e.g. the user pressing next while a watchdog is running).
      var encoreGen = 0;
      function applyEncoreMeta() {
        if (!__encoreMeta || !('mediaSession' in navigator)) return;
        try {
          var m = new MediaMetadata({
            title: __encoreMeta.title || '',
            artist: __encoreMeta.artist || '',
            album: __encoreMeta.album || '',
            artwork: __encoreMeta.art ? [{ src: __encoreMeta.art, sizes: '544x544', type: 'image/jpeg' }] : []
          });
          // Write through the saved prototype setter — the instance property is
          // patched to swallow (site) writes while __encoreOwnsMeta is set.
          if (window.__encoreSetMetadata) { window.__encoreSetMetadata(m); }
          else { navigator.mediaSession.metadata = m; }
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
              // 1. iOS autoplay policy can leave the player CUED (5)/UNSTARTED
              //    (-1) instead of playing — nudge playVideo() until it starts.
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
                  // committing our load (or reporting the audio counterpart's
                  // sibling id), and reloading would restart it every 500ms —
                  // a loop that stopped playback from ever starting.
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
        setMeta: function (m) { __encoreMeta = m; window.__encoreOwnsMeta = true; applyEncoreMeta(); reassertEncoreMeta(); },
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
              // iPhone WKWebView refuses to RENDER a video element that lacks
              // the playsinline attribute (desktop YouTube never sets it —
              // desktop doesn't need it): audio plays, the frame stays black.
              document.querySelectorAll('video').forEach(function (v) {
                v.setAttribute('playsinline', '');
                v.setAttribute('webkit-playsinline', '');
              });
              // Undo lowData and force a re-negotiation at the current spot so
              // the player refetches segments WITH the video track (it decoded
              // audio-only while parked at 1×1).
              if (p.setPlaybackQualityRange) p.setPlaybackQualityRange('large', 'hd1080');
              if (p.setPlaybackQuality) p.setPlaybackQuality('large');
              if (p.seekTo && p.getCurrentTime) p.seekTo(p.getCurrentTime(), true);
              // Report what the video element actually sees a moment later —
              // videoWidth 0 = no video track; readyState/inline tell the rest.
              setTimeout(function () {
                try {
                  var v = document.querySelector('video');
                  send({ event: 'videoDebug',
                         n: document.querySelectorAll('video').length,
                         w: v ? v.videoWidth : -1,
                         h: v ? v.videoHeight : -1,
                         rs: v ? v.readyState : -1,
                         paused: v && v.paused ? 1 : 0,
                         inline: v && v.hasAttribute('playsinline') ? 1 : 0,
                         app: document.querySelector('ytmusic-app') ? 1 : 0 });
                } catch (e) {}
              }, 2500);
            } else {
              if (p.setPlaybackQualityRange) p.setPlaybackQualityRange('tiny', 'tiny');
            }
          } catch (e) {}
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

// MARK: - Web content process recovery

extension PlayerEngine: WKNavigationDelegate {
    /// iOS killed the web view's content process (memory pressure). Without
    /// this the page stays dead for the rest of the session and nothing plays
    /// until the app is relaunched.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.player.error("web content process TERMINATED — reloading site")
        reloadSite()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.player.error("site navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Log.player.error("site load failed: \(error.localizedDescription)")
    }
}

// `private` in the original single-file engine — PlayerEngine's own init
// (now in MobilePlayer.swift) instantiates this, so it needs module access.
final class BridgeHandler: NSObject, WKScriptMessageHandler {
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
