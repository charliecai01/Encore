# Known bugs / disabled features

## Podcasts — RE-ENABLED (2026-06-21)

Podcasts were re-enabled in both apps (they were disabled 2026-06-16 as too
buggy). The entry points are restored — iOS Library "Podcasts" tab + `Nav.open`,
macOS sidebar + `Nav.open` + route restore — and the iOS episode player UI
(variable speed + ±15/30s skip) is back.

### Bugs fixed this pass
- **Episode controls showed for songs / vice versa (incl. lock screen).** Root
  cause: the shared track parser (`Parsers.track(fromMRLIR:)`, used by
  `playlist(id:)`) never set `isEpisode`, so episodes inside a playlist (e.g.
  "New Episodes") parsed as plain songs → song controls in-app and next/prev on
  the lock screen. Now detected via `musicVideoType` (…_PODCAST_EPISODE) so
  `isEpisode` is set wherever episodes appear, and `configureRemoteCommands`
  switches the lock screen to skip-forward/back for episodes.
- **Episode row play/pause restarted the show.** Tapping the (pause-looking)
  button on the now-playing episode now toggles play/pause instead of reloading
  the collection from that episode.

### Needs on-device verification (Charlie)
- **Tapping "New Episodes" / "Episodes for Later" played instantly instead of
  showing the episode list.** Hypothesis: these auto-playlists come back with a
  `watchPlaylistEndpoint` (no browse endpoint) → parsed as a `.station` →
  `Nav.open(.station)` plays immediately. Couldn't confirm the exact card shape
  without the live response. **Action:** tap each on device; if it still plays
  instantly, capture what `CardItem.kind`/endpoint it resolves to so the routing
  can be fixed precisely (likely: route episode stations to a list view).
- Episode playback through the WKWebView (start/stall/resume), and whether an
  episode auto-advances into music radio when it ends.
