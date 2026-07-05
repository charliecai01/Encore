# Podcasts — feature guide

**Status: ENABLED (2026-07-03)** with the Apple-Podcasts-style experience.
The **video sub-feature is DISABLED (2026-07-04)** — see the known bug below.

- **Dedicated podcast Now Playing screen on iOS** (`PodcastNowPlayingScreen`,
  chosen by `NowPlayingSwitcher` when `current.isEpisode`): artwork, release
  date, episode title + show, scrubber, ±15/30s skip, **speed 0.8–2×**, sleep,
  AirPlay, **mark-as-played**. Splitting the screens killed the old bug where
  the song/podcast UIs mixed and a speed tap could speed up songs
  (`setPlaybackRate` additionally only applies live to episodes).
- **macOS: Apple-Podcasts-style player bar** — when an episode plays, the
  bottom bar swaps shuffle/prev/next/repeat for **speed · back-15 · play ·
  forward-30**. Speed (0.8–2×) is episode-only on macOS too.
- **Resume where you left off** — `EncoreCore.EpisodeProgress` (UserDefaults,
  unit-tested) saves the position every ~5s and on pause/track-change; both
  engines resume at −5s of the saved spot (skips: <20s in, or nearly done).
  Covered on BOTH entry paths: tapping an episode row (`load()`) and a
  restored session (`restoreSession()`/`restore()` — songs deliberately
  restart at 0:00 there, episodes must not). Finishing an episode auto-marks
  it played and clears the resume point; marking played by hand also clears.
- **Progress bars on episode rows** (BOTH platforms — iOS `EpisodeRow`, macOS
  `MacEpisodeRow`): partially played episodes show a small accent bar +
  "N min left" in place of the duration, like Apple Podcasts. The row list
  decodes `EpisodeProgress.all()` once per render, not per row.
- **Background/lock-screen playback (iOS)** — episodes are VIDEO streams with
  **no audio counterpart** (probed live 2026-07-05: `audioCounterpart` nil,
  zero `playlistPanelVideoWrapperRenderer` pairings), and iOS suspends
  WKWebView video on lock, which paused podcasts the moment the screen went
  off. Fix: when a pause lands while the user still wants playback and the
  app just resigned active (and it's NOT an explicit pause or a call/Siri
  interruption — `userWantsPlayback` / `audioInterrupted` guards), the engine
  nudges `play()` — WebKit resumes the element AUDIO-ONLY in the background.
  Bounded at 6 nudges; reset on play state / foreground.
- **Home shelf: "New Podcast Episodes"** (BOTH platforms) — the RDPN
  "New Episodes" feed (latest episodes from subscribed shows, i.e. TheMove)
  rendered as track rows at the top of Home, gated on `PodcastFeature.enabled`.

To disable everything: set `PodcastFeature.enabled = false` in
[`Encore/Sources/EncoreCore/PodcastFeature.swift`](Encore/Sources/EncoreCore/PodcastFeature.swift)
and rebuild (macOS: `Encore/scripts/build_app.sh`; iOS:
`Encore/scripts/deploy_ios.sh`).

## Known bug: podcast VIDEO renders black — sub-feature disabled (2026-07-04)

`PodcastFeature.videoEnabled = false` hides the video buttons (iOS podcast Now
Playing screen; macOS player-bar episode transport). Audio podcasts are
unaffected. The code is intact behind the flag:
- iOS: `PodcastVideoScreen` (portrait-first full-screen player with a rotate-
  to-landscape button; `OrientationLock` + `AppDelegate.orientationMask` keep
  the rest of the app portrait) + `PodcastVideoHost` web-view re-parenting.
- macOS: `PodcastVideoSheet` (960×620, PlayerBar.swift) hosting `VideoSurface`.

**Symptom:** audio plays, video area stays black (reproduced with
`T_ZTAlYVcOE`, which definitely has video). Everything tried so far, all still
in place and none sufficient on iOS:
1. `playsinline` + `webkit-playsinline` stamped on the video element
   (an iPhone WKWebView won't render inline video without them; desktop
   YouTube never sets them).
2. Quality bump to `large…hd1080` (undoing the iOS `lowData()` 'tiny' cap)
   plus `seekTo(currentTime)` to force a stream re-negotiation — the theory
   being WebKit decoded audio-only while the web view sat parked at 1×1.
3. Full-screen re-parenting of the web view so it's genuinely visible.

**Next debugging step (already wired):** `videoMode(true)` emits a
`videoDebug` bridge event ~2.5s in — video element count, `videoWidth/Height`,
`readyState`, `paused`, inline attribute, desktop-DOM check — logged to the
unified log (subsystem `dev.charlie.encore`). Read it while toggling video:
`videoWidth == 0` → YouTube served no video track (likely needs a full
`loadVideoById` reload while visible, not a seek); `videoWidth > 0` but black
→ compositing/CSS problem. The one live-capture attempt via
`devicectl … launch --console` exited without attaching; use
`log stream --device --predicate 'subsystem == "dev.charlie.encore"'` or
Console.app instead. Note macOS video was never user-verified either (no UI
button existed until 2026-07-03), so don't assume the site still supports
video in this headless-player setup — verify on macOS first, it's easier to
inspect (Safari → Develop → the app's web view).

## What the flags control (gated touch points)

Everything reads `PodcastFeature.enabled`:

| Area | File | Behaviour when `false` |
|---|---|---|
| Library "Podcasts" tab (iOS) | `iOS/Sources/MobileServices.swift` `LibraryTab.visible` | tab hidden |
| Library "Podcasts" item (macOS) | `macOS/Nav.swift` `LibraryTab.visible` | sidebar item hidden |
| Tapping a podcast card (both) | `Nav.open(_:)` `.podcast` | no-op |
| Restoring a saved show route (macOS) | `macOS/Nav.swift` `decode(_:)` | returns `nil` |
| Podcast Now Playing screen (iOS) | `iOS/Sources/PodcastNowPlaying.swift` `NowPlayingSwitcher` | episodes get the song screen |
| Podcast transport in the player bar (macOS) | `macOS/PlayerBar.swift` `transport` | episodes get the song transport |
| Mark-as-played button + menu on episode rows (iOS) | `iOS/Sources/MobileScreens.swift` `TrackRowView` | hidden |
| Episodes inside playlists (e.g. "New Episodes") | `Sources/EncoreCore/YTM.swift` `playlist(id:)` | not parsed, so the playlist reads empty |

`PodcastFeature.videoEnabled` additionally gates the two video buttons (iOS
`PodcastNowPlayingScreen`, macOS `PlayerBar`), currently `false` per the bug
above.

Not gated (kept live on purpose — harmless and shared/tested):
- `EncoreCore` parsing/models: `podcastShow`, `libraryPodcasts`,
  `P.podcastEpisodes`, `Track.isEpisode`, the `musicVideoType` episode
  detection in `P.track(fromMRLIR:)`, `PlayedEpisodes`, `EpisodeProgress`
  (recording keeps running), the `.podcast` `CardItem` kind.
- `PodcastScreen`/`EpisodeRow` (iOS), `PodcastView`/`MacEpisodeRow` (macOS),
  the `.podcastShow` routes — present but unreachable when navigation is
  gated.

## Architecture

- **Browsing:** `YTM.podcastsHome()` / `libraryPodcasts()` (browseId
  `FEmusic_library_non_music_audio_list`) → your subscribed shows + discover
  feed. Show page: `YTM.podcastShow(browseId:)`.
- **Episodes parse** from `musicMultiRowListItemRenderer` via
  `P.podcastEpisodes(...)`, which sets `isEpisode = true`, plus `dateText`,
  `details`, and `durationSeconds` (from the `durationText` label).
- **Episode detection in playlists:** the generic track parser
  (`P.track(fromMRLIR:)`) tags a track `isEpisode` when its `musicVideoType`
  contains `EPISODE`/`PODCAST` (confirmed live value:
  `MUSIC_VIDEO_TYPE_PODCAST_EPISODE`). This drives the episode UI for episodes
  that live inside a playlist.
- **Playback** uses the same WKWebView player as songs; `isEpisode` switches
  the Now Playing surface (iOS screen / macOS bar transport), the playback
  rate handling, and the lock-screen remote commands
  (`configureRemoteCommands(forEpisode:)` → skip-forward/back).
- **Played state:** `PlayedEpisodes` (UserDefaults `playedEpisodeIds`, shared
  across both apps). No server-side played flag exists in YT Music.
- **Resume state:** `EpisodeProgress` (UserDefaults `episodeProgressById`,
  capped at 500 newest entries). Live coverage: `AuthenticatedLiveTests`
  guards show-page + RDPN parsing against the real account.

### The "New Episodes" gotcha (important)

"New Episodes" and "Episodes for Later" are auto-playlists, not shows. Confirmed
live against the account:
- "New Episodes" → `playlistId = RDPN` (note the `RD` prefix), `browseId
  VLRDPN`, pageType `MUSIC_PAGE_TYPE_PLAYLIST`. Its episodes use
  `musicMultiRowListItemRenderer`.
- "Episodes for Later" → `playlistId = SE`; genuinely empty until you save an
  episode (••• → Save episode for later).

Two bugs were fixed during an earlier enable and the fixes are still in place
(they're general routing/parsing, not gated):
1. `Nav.open(.playlist)` no longer auto-plays `RD`-prefixed playlists — they
   open as a list. (True radios arrive as `.station` and still play instantly.)
2. `YTM.playlist(id:)` merges `podcastEpisodes`, so an episode playlist isn't
   empty — **this part is gated**, so with podcasts off "New Episodes" opens as
   an (empty) list rather than instant-playing.

## History
- 2026-06-16 disabled (too buggy) · 2026-06-21 re-enabled with routing/control
  fixes · 2026-06-22 disabled behind `PodcastFeature.enabled`.
- 2026-07-03 re-enabled with the Apple-Podcasts experience: dedicated iOS Now
  Playing screen, macOS bar transport, resume via `EpisodeProgress`, episode
  progress bars, auto-mark-played, live parsing tests.
- 2026-07-04 video sub-feature disabled (`videoEnabled = false`) after the
  black-screen bug resisted the playsinline/quality/re-parent fixes; resume
  extended to restored sessions and progress bars added on macOS the same day.
