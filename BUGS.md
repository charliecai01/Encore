# Known bugs / disabled features

## Podcasts — RE-ENABLED (2026-06-21)

Podcasts were re-enabled in both apps (disabled 2026-06-16 as too buggy). Entry
points restored — iOS Library "Podcasts" tab + `Nav.open`, macOS sidebar +
`Nav.open` + route restore — and the iOS episode player UI (variable speed +
±15/30s skip) is back.

### Bugs fixed this pass (verified against the live account via encore-smoke)
- **Tapping "New Episodes" played instantly instead of listing.** Root cause: it
  is a browsable playlist whose `playlistId` is `RDPN`, and `Nav.open` treated
  any `RD`-prefixed playlist as a radio → instant play. Fixed: browsable
  `.playlist` cards always open the list; true radios arrive as `.station` and
  still play instantly. (`Nav.open` in both apps.)
- **"New Episodes" list was empty even when routed to a list.** Root cause: its
  episodes use `musicMultiRowListItemRenderer`, which the regular playlist parser
  skips. Fixed: `YTM.playlist(id:)` now also parses `podcastEpisodes` and merges
  them. Confirmed live: `playlist("RDPN")` → 1 episode, `isEpisode=true`.
- **Episode vs song controls mixed up (in-app + lock screen).** Root cause: the
  shared track parser never set `isEpisode`, so episodes in a playlist parsed as
  songs. Fixed: detected via `musicVideoType` (…_PODCAST_EPISODE, confirmed
  present in the live data); `configureRemoteCommands` switches the lock screen
  to skip-forward/back for episodes.
- **Episode row play/pause restarted the show** → now toggles play/pause.

### Not a bug
- **"Episodes for Later" shows empty.** It's the manual "save for later" list
  (`plId=SE`) and is genuinely empty (0 tracks) until you save an episode. Opens
  correctly as a list.

### Still worth verifying on device
- Episode playback through the WKWebView (start/stall/resume), and whether an
  episode auto-advances into music radio when it ends.
- Episodes opened from a playlist render as standard track rows (they play with
  episode controls). The richer EpisodeRow UI (date/played toggle) only shows on
  the dedicated podcast-show page — a possible follow-up if you want it in
  playlists too.
