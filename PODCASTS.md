# Podcasts — feature guide

**Status: ENABLED (2026-07-03)** with the Apple-Podcasts-style experience:

- **Dedicated podcast Now Playing screen on iOS** (`PodcastNowPlayingScreen`,
  chosen by `NowPlayingSwitcher` when `current.isEpisode`): artwork, release
  date, episode title + show, scrubber, ±15/30s skip, **speed 0.8–2×**, sleep,
  AirPlay, **mark-as-played**, and a **video button** that opens the episode's
  video **full-screen in landscape** (`PodcastVideoScreen` — tap to show/hide
  transport; the app stays portrait everywhere else). Splitting the screens killed the old bug where
  the song/podcast UIs mixed and a speed tap could speed up songs
  (`setPlaybackRate` additionally only applies live to episodes).
- **Resume where you left off** — `EncoreCore.EpisodeProgress` (UserDefaults,
  unit-tested) saves the position every ~5s and on pause/track-change; both
  engines resume at −5s of the saved spot (skips: <20s in, or nearly done).
  Finishing an episode auto-marks it played and clears the resume point.
- **Progress bars on episode rows** (iOS show pages): partially played
  episodes show a small bar + "N min left", like Apple Podcasts.
- **macOS: Apple-Podcasts-style player bar** — when an episode plays, the
  bottom bar swaps shuffle/prev/next/repeat for **speed · back-15 · play ·
  forward-30 · video**. The video button opens a 960×620 sheet
  (`PodcastVideoSheet` in PlayerBar.swift) hosting the shared web view with
  the video-mode CSS + a small transport; closing it parks the web view.
  Speed (0.8–2×) is episode-only on macOS too, same as iOS.

To disable: set `PodcastFeature.enabled = false` in
[`Encore/Sources/EncoreCore/PodcastFeature.swift`](Encore/Sources/EncoreCore/PodcastFeature.swift)
and rebuild (macOS: `Encore/scripts/build_app.sh`; iOS:
`Encore/scripts/deploy_ios.sh`).

## What the flag controls (gated touch points)

Everything reads `PodcastFeature.enabled`:

| Area | File | Behaviour when `false` |
|---|---|---|
| Library "Podcasts" tab (iOS) | `iOS/Sources/MobileServices.swift` `LibraryTab.visible` | tab hidden |
| Library "Podcasts" item (macOS) | `macOS/Nav.swift` `LibraryTab.visible` | sidebar item hidden |
| Tapping a podcast card (both) | `Nav.open(_:)` `.podcast` | no-op |
| Restoring a saved show route (macOS) | `macOS/Nav.swift` `decode(_:)` | returns `nil` |
| Episode player UI — speed + ±15/30s skip (iOS) | `iOS/Sources/NowPlayingScreen.swift` | episodes use the normal song transport |
| Mark-as-played button + menu on episode rows (iOS) | `iOS/Sources/MobileScreens.swift` `TrackRowView` | hidden |
| Episodes inside playlists (e.g. "New Episodes") | `Sources/EncoreCore/YTM.swift` `playlist(id:)` | not parsed, so the playlist reads empty |

Not gated (kept live on purpose — harmless and shared/tested):
- `EncoreCore` parsing/models: `podcastShow`, `libraryPodcasts`,
  `P.podcastEpisodes`, `Track.isEpisode`, the `musicVideoType` episode
  detection in `P.track(fromMRLIR:)`, `PlayedEpisodes`, the `.podcast`
  `CardItem` kind. These just produce data; nothing surfaces it while the flag
  is off.
- `PodcastScreen`/`EpisodeRow` (iOS), `PodcastView`/`MacEpisodeRow` (macOS),
  the `.podcastShow` routes, `CollectionView`'s `.podcast` kind — all present
  but unreachable because navigation into them is gated.

## Architecture (for when you revive it)

- **Browsing:** `YTM.podcastsHome()` / `libraryPodcasts()` (browseId
  `FEmusic_library_non_music_audio_list`) → your subscribed shows + discover
  feed. Show page: `YTM.podcastShow(browseId:)`.
- **Episodes parse** from `musicMultiRowListItemRenderer` via
  `P.podcastEpisodes(...)`, which sets `isEpisode = true`, plus `dateText`,
  `details`, and `durationSeconds` (from the `durationText` label).
- **Episode detection in playlists:** the generic track parser
  (`P.track(fromMRLIR:)`) tags a track `isEpisode` when its `musicVideoType`
  contains `EPISODE`/`PODCAST` (confirmed live value:
  `MUSIC_VIDEO_TYPE_PODCAST_EPISODE`). This is what drives episode controls
  for episodes that live inside a playlist.
- **Playback** uses the same WKWebView player as songs; `isEpisode` only changes
  the transport UI and the lock-screen remote commands
  (`configureRemoteCommands(forEpisode:)` → skip-forward/back instead of
  next/prev).
- **Played state:** `PlayedEpisodes` (UserDefaults `playedEpisodeIds`, shared
  across both apps). No server-side played flag exists in YT Music.

### The "New Episodes" gotcha (important)

"New Episodes" and "Episodes for Later" are auto-playlists, not shows. Confirmed
live against the account:
- "New Episodes" → `playlistId = RDPN` (note the `RD` prefix), `browseId
  VLRDPN`, pageType `MUSIC_PAGE_TYPE_PLAYLIST`. Its episodes use
  `musicMultiRowListItemRenderer`.
- "Episodes for Later" → `playlistId = SE`; genuinely empty until you save an
  episode (••• → Save episode for later).

Two bugs were fixed during the last enable and the fixes are still in place
(they're general routing/parsing, not gated):
1. `Nav.open(.playlist)` no longer auto-plays `RD`-prefixed playlists — they
   open as a list. (True radios arrive as `.station` and still play instantly.)
2. `YTM.playlist(id:)` merges `podcastEpisodes`, so an episode playlist isn't
   empty — **this part is gated**, so with podcasts off "New Episodes" opens as
   an (empty) list rather than instant-playing.

## History / things to verify on re-enable
- Disabled first on 2026-06-16 (too buggy), re-enabled 2026-06-21 with the
  routing + control fixes above, disabled again 2026-06-22 behind this flag.
- When re-enabling, retest on device: episode start/stall/resume over cellular,
  that episode vs song controls don't mix up (in-app and lock screen), and that
  mark-as-played persists across the show page and the playlist view.
