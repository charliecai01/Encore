# Podcasts — feature guide

**Status: DISABLED (2026-06-22).** The podcast UI is hidden in both the macOS
and iOS apps. The code is fully intact and gated behind one flag, so re-enabling
is a one-line change plus a rebuild.

## How to re-enable

1. In [`Encore/Sources/EncoreCore/PodcastFeature.swift`](Encore/Sources/EncoreCore/PodcastFeature.swift),
   set:
   ```swift
   public static var enabled = true
   ```
2. Rebuild both apps:
   - macOS: `Encore/scripts/build_app.sh`
   - iOS device: `xcodebuild … -scheme EncoreiOS … build` then
     `xcrun devicectl device install …` (see `encore-ios-device-deploy`).
3. That's it. Everything below switches back on.

To disable again, set the flag back to `false` and rebuild.

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
