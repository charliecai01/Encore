import Foundation

/// Master switch for the **Most Played** UI — your personal per-song play counts.
///
/// Enabled (2026-07-02): counts are **per-device** — there is no cross-device
/// sync, so each install tallies its own plays. That's accepted as the current
/// behavior. Surfaces the iOS Library "Most Played" entry + screen and the
/// macOS "Most Played" sidebar item.
///
/// Play *recording* (`PlayCounts.record`, called by both engines) runs
/// regardless of this flag, so the history accumulates even if the UI is off.
/// Cross-device sync remains a future task — the cleanest path (iCloud) needs a
/// paid Apple Developer account; see the git log around 2026-06-23 for options.
public enum PlayCountsFeature {
    public static var enabled = true
}
