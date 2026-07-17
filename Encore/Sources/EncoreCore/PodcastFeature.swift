import Foundation

/// Master switch for the podcast feature — browsing subscribed shows, the
/// podcast show page, episode lists inside playlists, and the episode player UI.
///
/// **Disabled (2026-07-13) at Charlie's request.** The full Apple-Podcasts
/// experience (dedicated iOS Now Playing screen, macOS bar transport, resume
/// via `EpisodeProgress`, progress bars, Home shelf, pinned shows) remains
/// intact behind this flag — set to `true` and rebuild to bring it all back.
/// See `PODCASTS.md` for the gated touch points and the video known-bug.
public enum PodcastFeature {
    /// `true` to surface podcasts in the UI. Kept as a `var` (not a `let`) so the
    /// gates read as ordinary runtime checks rather than dead code.
    public static var enabled = false

    /// The podcast VIDEO player — DISABLED (2026-07-04): the video element
    /// renders black on iOS (audio keeps playing) despite playsinline +
    /// quality bump + seekTo re-negotiation; see PODCASTS.md "Known bug".
    /// Gates the video button in the iOS podcast Now Playing screen and the
    /// macOS player-bar episode transport. Flip to `true` to bring them back.
    public static var videoEnabled = false
}
