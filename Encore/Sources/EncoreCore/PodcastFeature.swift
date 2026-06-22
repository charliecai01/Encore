import Foundation

/// Master switch for the podcast feature — browsing subscribed shows, the
/// podcast show page, episode lists inside playlists, and the episode player UI
/// (variable speed + ±15/30s skip + mark-as-played).
///
/// The feature is **disabled** by default: it's not ready for daily use. All
/// podcast UI across both apps is gated on this flag, so flipping it to `true`
/// and rebuilding re-enables everything. See `PODCASTS.md` for the full
/// re-enable guide and the list of gated touch points.
public enum PodcastFeature {
    /// `true` to surface podcasts in the UI. Kept as a `var` (not a `let`) so the
    /// gates read as ordinary runtime checks rather than dead code.
    public static var enabled = false
}
