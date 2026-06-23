import Foundation

/// Master switch for the **Most Played** UI — your personal per-song play counts.
///
/// Disabled for now: without cross-device sync the counts are per-device, which
/// isn't the intended experience. Flip to `true` and rebuild to bring it back.
/// Re-enabling surfaces: the iOS Library "Most Played" entry + screen, and the
/// macOS "Most Played" sidebar item.
///
/// Note: play *recording* (`PlayCounts.record`, called by both engines) keeps
/// running while this is off, so your listening history accumulates and is ready
/// the moment you re-enable. Cross-device sync is a separate future task — the
/// cleanest path (iCloud) needs a paid Apple Developer account; see the chat
/// history / git log around 2026-06-23 for the options discussed.
public enum PlayCountsFeature {
    public static var enabled = false
}
