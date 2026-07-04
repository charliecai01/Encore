import Foundation

/// Master switch for the podcast feature — browsing subscribed shows, the
/// podcast show page, episode lists inside playlists, and the episode player UI.
///
/// **Enabled (2026-07-03)** with the Apple-Podcasts-style experience: a
/// dedicated podcast Now Playing screen on iOS (speed, ±15/30s skip, video
/// toggle, mark-as-played), resume-where-you-left-off via `EpisodeProgress`,
/// and progress bars on episode rows. Set to `false` and rebuild to hide all
/// podcast UI again — see `PODCASTS.md` for the gated touch points.
public enum PodcastFeature {
    /// `true` to surface podcasts in the UI. Kept as a `var` (not a `let`) so the
    /// gates read as ordinary runtime checks rather than dead code.
    public static var enabled = true

    /// The podcast VIDEO player — DISABLED (2026-07-04): the video element
    /// renders black on iOS (audio keeps playing) despite playsinline +
    /// quality bump + seekTo re-negotiation; see PODCASTS.md "Known bug".
    /// Gates the video button in the iOS podcast Now Playing screen and the
    /// macOS player-bar episode transport. Flip to `true` to bring them back.
    public static var videoEnabled = false
}
