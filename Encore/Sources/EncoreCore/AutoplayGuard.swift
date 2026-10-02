import Foundation

/// Document-START user script, injected by both engines ahead of the
/// controller. While suppressed (paused / launch guard / sleep stop) it pauses
/// any media element in the capture phase of its `play`/`playing` events.
///
/// Why this exists on top of the controller's `onStateChange` self-pause: the
/// site's player only reports state 1 once playback is already rendering, so
/// that pause always trailed real audio by tens of ms (log: `state=1
/// selfPaused=true` then `state=2` ~40ms later) — audible as a short blip.
/// The `play` event fires as soon as the element leaves the paused state,
/// ahead of `playing`, and this listener exists before ANY site script runs,
/// so a reloaded page's auto-resume can't slip out before the controller is
/// even injected.
///
/// Starts suppressed (matching native's default); the controller's
/// `__encore.suppress(v)` keeps `window.__encoreGuard.suppressed` in sync.
/// Deliberately pause-only — muting the element would leak into the site's
/// persisted volume state and risk silent playback later.
public enum AutoplayGuard {
    public static let script = #"""
    (function () {
      if (window.__encoreGuard) { return; }
      var g = window.__encoreGuard = { suppressed: true };
      function stop(e) {
        var el = e.target;
        if (g.suppressed && el && typeof el.pause === 'function') {
          try { el.pause(); } catch (x) {}
        }
      }
      document.addEventListener('play', stop, true);
      document.addEventListener('playing', stop, true);
    })();
    """#
}
