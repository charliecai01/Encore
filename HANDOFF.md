# Encore — Agent Handoff

A native **macOS + iOS YouTube Music client** that replaces Google's UI with a
Spotify/Apple-Music/QQ-Music–inspired interface, powered by the user's own
YouTube Music **Premium** account. This doc is the single source of truth for
picking up the work without the original chat history.

> **User:** Charlie (charliecai00@gmail.com / GitHub `charliecai01`). He is
> **cost-conscious about agent sessions** — be efficient, don't over-verify,
> don't re-derive context. He has **Premium**. He validates features himself
> and reports bugs tersely (often a screenshot + one line). When he says a
> feature "doesn't work like the website," he usually means the real
> YouTube-Music web behavior is the spec.

---

## 1. Repo layout

```
/Users/charlie/Documents/9.YTMusic/            ← git root (remote: charliecai01/Encore, branch main)
├── HANDOFF.md                                 ← this file
├── README.md
├── BUGS.md                                    ← known bugs + feature-flag states (podcasts OFF, Most Played ON/per-device)
├── PODCASTS.md                                ← podcast feature guide + one-line re-enable steps
├── .gitignore                                 ← ignores .build/, build/, iOS/.build_ios/, iOS/.build_device/, generated xcodeproj/Info.plist/entitlements
└── Encore/
    ├── Package.swift                          ← SwiftPM: EncoreCore (lib), Encore (macOS exe), encore-smoke (exe)
    ├── scripts/
    │   ├── build_app.sh                       ← builds macOS Encore.app AND installs to /Applications
    │   ├── deploy_ios.sh                      ← one-command iOS device build+install (ENCORE_DEVICE_ID/ENCORE_TEAM_ID overridable)
    │   ├── make_icon.swift                    ← macOS .icns generator
    │   └── make_ios_icon.swift                ← iOS app-icon PNG generator (full-bleed, opaque)
    ├── assets/                                ← macOS AppIcon.icns + icon_1024.png
    ├── Sources/
    │   ├── EncoreCore/                        ← PLATFORM-AGNOSTIC core (Foundation + CryptoKit only)
    │   │   ├── InnerTube.swift                ← low-level YouTube InnerTube API client + SAPISID auth
    │   │   ├── YTM.swift                      ← high-level API (search/browse/library/queue/lyrics/podcasts/playlist-edit)
    │   │   ├── Parsers.swift                  ← resilient recursive parsers for InnerTube JSON
    │   │   ├── Models.swift                   ← Track (incl. podcast isEpisode/dateText/details), CardItem, Shelf, CollectionPage…
    │   │   ├── JSONValue.swift                ← dynamic JSON wrapper with findAll/findFirst tree search
    │   │   ├── LibrarySort.swift              ← shared, unit-tested sort/filter for tracks & cards (both apps delegate here)
    │   │   ├── LyricsService.swift            ← multi-provider orchestration (auto chain)
    │   │   ├── LyricsProviders.swift          ← NetEase, Musixmatch, Genius
    │   │   ├── LRCLib.swift                   ← LRCLIB synced-lyrics provider + LRC parser
    │   │   ├── CJK.swift                      ← Simplified↔Traditional Chinese normalization (ICU transform)
    │   │   ├── Discovery.swift                ← Discover-shelf curation (pure, unit-tested)
    │   │   ├── Log.swift                      ← os.Logger facade, subsystem dev.charlie.encore (DEBUG also → stderr)
    │   │   ├── PlayCounts.swift, PlayCountsFeature.swift ← personal play counts + UI flag (ON/per-device — see BUGS.md)
    │   │   ├── PodcastFeature.swift           ← podcast UI flag (OFF — see PODCASTS.md)
    │   │   └── PlayedEpisodes.swift           ← episode played-state store (UserDefaults)
    │   └── encore-smoke/                      ← CLI: `swift run encore-smoke` hits the LIVE API unauthenticated
    ├── macOS/                                 ← macOS SwiftUI app (AppKit) — Package target `Encore`, path "macOS"
    ├── Tests/EncoreCoreTests/                 ← XCTest for the shared core (run: `swift test`) — covers BOTH apps' logic; incl. live-API checks that auto-skip offline
    └── iOS/                                   ← iOS app (folder; Xcode project/scheme still named EncoreiOS)
        ├── project.yml                        ← XcodeGen spec → EncoreiOS.xcodeproj (GENERATED, gitignored)
        └── Sources/
            ├── AppMain.swift                  ← @main AppDelegate + PhoneSceneDelegate; AVAudioSession setup
            ├── MobilePlayer.swift             ← iOS PlayerEngine (UIKit port); playback speed, skip 15/30, call-interruption handling
            ├── MobileServices.swift           ← Theme, DiskCache, PageCache, AuthManager (auto-sign-in), LibraryStore, Nav, Login
            ├── MobileRoot.swift               ← TabView (Home/Search/Library), MiniPlayer, ArtworkView, route destinations
            ├── MobileScreens.swift            ← Home/Search/Library/Collection/Artist/Browse/PodcastScreen + sort (delegates to LibrarySort)
            ├── NowPlayingScreen.swift         ← full-screen now playing (Song/Lyrics/Queue); podcast transport for episodes
            ├── DevCredentials.swift           ← OPTIONAL dev auto-sign-in cookie; committed EMPTY, real value skip-worktree'd (see §7)
            ├── CarPlay.swift                  ← CarPlaySceneDelegate (currently disabled in Info.plist — see §7)
            └── Assets.xcassets/AppIcon.appiconset/  ← iOS app icon
```

---

## 2. How it works (architecture)

- **`EncoreCore`** is a pure-Swift library (Foundation + CryptoKit). It is the
  **shared brain** for both apps. It's a Swift reimplementation of the relevant
  parts of [ytmusicapi](https://github.com/sigma67/ytmusicapi). It must be
  exposed as a `.library` **product** in `Package.swift` (not just a target) so
  the external iOS Xcode project can link it.
- **InnerTube API**: `InnerTube.swift` POSTs to `https://music.youtube.com/youtubei/v1/<endpoint>`
  with a `WEB_REMIX` (or `ANDROID_MUSIC` for timed lyrics) client context.
  Auth = the browser cookies from the in-app Google sign-in, mirrored into a
  `Cookie` header + a `SAPISIDHASH` `Authorization` header (SHA-1 of
  `timestamp SAPISID origin`).
- **Parsers are deliberately loose**: they recursively search the JSON tree
  (`JSONValue.findAll/findFirst`) so minor YouTube layout changes degrade
  gracefully. When a page breaks, run `encore-smoke` first to see if it's an
  API/parse problem vs. a UI problem.
- **Playback** (the key trick, borrowed from pear-devs/pear-desktop a.k.a. the
  renamed th-ch/youtube-music): a **hidden `WKWebView`** loads the real
  `music.youtube.com` signed into the user's account. An injected JS controller
  (`window.__encore`, see `controllerScript` in the PlayerEngine) drives the
  site's `#movie_player` (load/play/pause/seek/volume) and reports state/time
  back over a script-message bridge 4×/sec **plus** an event-driven
  `onStateChange` hook (needed so the brief "ended" state isn't missed by
  polling). Everything else (queue, shuffle, radio, lyrics, media keys,
  CarPlay, now-playing) is native. Because it's the real site, Premium quality
  applies and plays count toward recommendations.
- **Auth**: in-app Google sign-in via `WKWebView` sharing
  `WKWebsiteDataStore.default()`. Google blocks "embedded/outdated" browsers,
  so the login view spoofs a current Safari UA (`Version/26.0`). There is also
  a **cookie-import fallback** (paste the `cookie:` header or a full
  `Copy as cURL` from DevTools) — this is how Charlie actually signed in.

---

## 3. Build & run

### macOS
```bash
cd Encore
./scripts/build_app.sh          # builds build/Encore.app AND installs to /Applications/Encore.app, relaunches if running
```
Only the Command Line Tools are needed for macOS, BUT full Xcode is installed
and may become the active toolchain; `build_app.sh` falls back to CLT if the
Xcode license isn't accepted.

### Live API smoke test (fast, no UI, unauthenticated)
```bash
cd Encore && swift run encore-smoke
```
Tests search/album/artist/queue/lyrics/podcasts/CJK against the live API. Run
this FIRST when a data/parsing bug is reported.

### Unit tests (fast; live checks auto-skip offline)
```bash
cd Encore && swift test          # EncoreCoreTests — the shared brain both apps use
```
Covers podcast duration/episode parsing, `Track` Codable tolerance, artwork URL
upscaling, CJK matching, and `LibrarySort` (ordering/filtering). Since both apps
delegate their sort/filter to `LibrarySort` and share `EncoreCore`, these guard
both platforms. Add tests here when you touch shared logic. The suite also
includes `LiveConnectionTests` — unauthenticated live-API parser checks that
skip (not fail) without network; set `ENCORE_SKIP_LIVE=1` to skip explicitly.

**`AuthenticatedLiveTests`** covers the SIGNED-IN response shapes: library
playlists, liked songs, personalized home + history, watch-queue parse (with
the like-status canary), and continuation accumulation (liked songs paginate
at 25/page, playlists at 100/page — counts above those prove the continuation
scoping works). The cookie is resolved at runtime — `ENCORE_TEST_COOKIE` env
var, else the local skip-worktree'd `iOS/Sources/DevCredentials.swift` — and
is NEVER committed; without one the class skips, so CI/fresh checkouts stay
green. Tests are read-only (no account mutations). If they fail while the
unauthenticated live tests pass, suspect an expired cookie first.

### iOS (needs full Xcode — already installed; license accepted)
```bash
cd Encore/iOS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate                     # regenerates EncoreiOS.xcodeproj from project.yml (xcodegen at /opt/homebrew/bin)
xcodebuild -project EncoreiOS.xcodeproj -scheme EncoreiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build_ios build
# install + run in the simulator:
xcrun simctl boot "iPhone 17 Pro"     # if not booted
APP=$(find .build_ios/Build/Products -name "EncoreiOS.app" -maxdepth 3 | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted dev.charlie.encore.ios
xcrun simctl io booted screenshot /tmp/x.png   # screenshot without GUI
```
**Do NOT build the simulator app with `CODE_SIGNING_ALLOWED=NO`** — the
resulting unsigned app fails to launch (FBSOpenApplicationServiceErrorDomain
code 4). Plain `xcodebuild … build` ad-hoc-signs for the simulator fine.

---

## 4. Git workflow (STANDING INSTRUCTION)

**Commit & push to GitHub after every build change.** Remote `origin` =
`https://github.com/charliecai01/Encore.git`, branch `main`. `gh` CLI is **not
installed** — use plain `git` (HTTPS, osxkeychain creds already work). Use
normal incremental commits; **do not force-push or amend**. End commit messages
with the Co-Authored-By: Claude line.

---

## 5. Hard-won gotchas (read before touching these areas)

- **iOS target/scheme is named `EncoreiOS`, not `Encore`.** The package's macOS
  executable target is also `Encore`; sharing the name pulls AppKit sources
  into the iOS build. Keep them distinct.
- **`EncoreCore` must stay a `.library` product** in `Package.swift`.
- **Now-playing layout bug (fixed, don't reintroduce):** a blurred backdrop
  `AsyncImage(...).aspectRatio(contentMode: .fill)` with **no frame** inflates
  the layout past the window, shoving controls/tabs off-screen (iOS) and
  hiding buttons on resize (macOS). Always pin background `.fill` images with
  `.frame(width:height:).clipped()`. iOS artwork uses an explicit square size,
  not `.aspectRatio(.fit)` in a flexible VStack.
- **Sleep timer:** the site's own autoplay can resume after the timer fires.
  The fix uses a `sleepStopActive` flag that force-re-pauses any
  site-initiated playback until the user explicitly plays. Don't make the
  pause conditional on `isPlaying`.
- **Session restore must stay PAUSED** on launch (both platforms). `loadedOnce`
  gates this; the ready/state handlers must not auto-play a restored track.
  (Confirmed desired behavior on both macOS and iOS.)
- **Likes: the watch-queue `currentLikeStatus` field went dead.** Verified live
  2026-07-02: YouTube removed per-item `likeStatus` from ALL playlistPanel
  renderers (even the LM liked-songs panel), and the response-level
  `likeButtonRenderer` is an unpersonalized INDIFFERENT — do NOT trust it for
  hearts. Heart state therefore rests on the liked-songs library seed +
  session toggles. The parse path (`P.queueResult`) and the engines'
  `if let status` hooks stay as harmless no-ops in case the field returns;
  `AuthenticatedLiveTests` carries a canary asserting that if it returns for a
  liked song it says LIKE.
- **Library completeness:** "Songs" and "Artists" are built from
  `LibraryStore.allKnownTracks()` = liked songs + the contents of **every**
  playlist (not just `FEmusic_liked_videos`). Playlist pagination must scope
  the continuation token to the track shelf (signed-in playlists carry a
  separate suggestions continuation) — `P.continuationToken`. Verified 500/500
  on a public playlist; caps: playlists 40 pages, liked songs 50.
- **CJK search:** Simplified queries also search the Traditional variant and
  merge (`CJK.toTraditional`); local filter boxes normalize via
  `String.matchNormalized`.
- **Performance:** `PlayerClock` isolates the 4 Hz time tick so it doesn't
  re-render every row; `PageCache`/`DiskCache` serve pages instantly then
  refresh in the background (Charlie dislikes fetch-every-visit spinners);
  `RemoteImage` is an NSCache-backed loader that sends the YT cookie for
  personalized art. Charlie prefers **performance over memory/storage**.
- **Computer-use verification is flaky** on the simulator (imprecise tap
  mapping) and the user runs **Magnet** + **NotchNook** + (sometimes) a window
  manager that intercept menu-bar/edge clicks. Prefer `xcrun simctl io booted
  screenshot` over GUI screenshots, and `simctl`/Bash over clicking when
  possible. The user has quit those utilities before when asked.
- **iOS lock-screen metadata is the PAGE's MediaSession, not our
  MPNowPlayingInfoCenter** — the WKWebView owns Now Playing on iOS.
  `__encore.setMeta` pushes our track's title/artist/art into the page, and
  the documentStart script PATCHES the `mediaSession.metadata` setter so site
  writes are swallowed while `window.__encoreOwnsMeta` is set (2026-07-03).
  Before that, the site's late metadata updates (slow fetches, SPA events
  mid-song) overwrote our artwork → stale art in Notification Center. Native
  `updateNowPlayingInfo` still runs as a fallback but the page wins on iOS.
- **iOS site-autoplay on launch (fixed, don't reintroduce):** iOS sets
  `mediaTypesRequiringUserActionForPlayback = []`, so the real site can
  auto-start the account's last track on a cold launch. A `suppressSiteAutoplay`
  flag (mirrors `sleepStopActive`) force-pauses any site-initiated playback
  until the user explicitly plays; cleared in `load()`/`togglePlay()`.
- **iOS track "jumps back to previous song" (fixed):** 250 ms polling misses the
  brief "ended" state, so the queue didn't advance and mismatch-recovery
  reloaded the stale `current`. The injected controller now also hooks
  `onStateChange` (parity with macOS) so ended is caught.
- **Album sort sentinel bug (fixed):** ordering by album used `?? "~"` to push
  album-less tracks last, but under locale-aware compare symbols sort FIRST.
  `LibrarySort` now handles missing albums explicitly (a unit test guards it).
- **Sort/filter lives in `LibrarySort` (EncoreCore), not the views.** It used to
  be copy-pasted in three view files and had drifted. Both apps delegate now —
  change sort behavior THERE and a `swift test` covers it.
- **XcodeGen globs at generation time:** after ADDING a new `.swift` under
  `iOS/Sources`, re-run `xcodegen generate` or the build fails with
  "cannot find X in scope" (the generated project doesn't see the new file).
- **`.build_device/` is gitignored** (device build output). Compiled objects can
  embed the dev sign-in cookie, so never un-ignore it / never `git add` it.
- **Restored-session first play needs a forced clean load:** on cold launch the
  site auto-resumes the account's last track — usually the SAME id as the
  restored `current` — so `ensure(id)`'s same-id path resumed the SITE's
  context (its auto-radio "Up Next", not our queue). A one-shot
  `forceReloadOnEngage` (set on restore, consumed on first play) makes
  `ensure()` do a clean `loadVideoById`. Both engines. Don't "simplify" the
  same-id resume path back.
- **Remote play/pause must be explicit, not a toggle (macOS):** the system
  sends `pauseCommand` on route changes (AirPods connect, another app plays);
  a toggle flips an already-paused app to PLAYING at random. `playCommand`
  acts only when paused, `pauseCommand` only when playing; only the media-key
  `togglePlayPauseCommand` toggles.
- **iOS music videos swap to their audio counterpart** before playing — iOS
  suspends background WKWebView *video* on lock (audio keeps running).
  `YTM.audioCounterpart(for:)` resolves the paired audio id from the watch
  response; `playingVideoId` tracks what's actually loaded so state-sync /
  ended / stall paths compare against the swapped id, not the canonical one.
- **Autoplay endless radio is continuation-driven:** re-seeding
  `RDAMVM<lastId>` when the queue ran out returned the same head tracks →
  dedup left nothing → playback stopped. Use the queue continuation token
  (`YTM.queueContinuation`), advance the cursor even when a page is all dupes;
  a fresh seed is only the fallback. The **toggle mirrors the site both ways**
  (2026-07-02): ON prefetches the tail immediately (also when playback enters
  the last queued track, so upcoming songs are visible before the queue ends);
  OFF strips the not-yet-played autoplay tracks so the queue returns to the
  user's own songs. Provenance lives in `autoplayTailIds` (only
  `extendQueueWithRadio` appends there; cleared on every new queue context;
  `playNext`/`addToQueue` remove the id — explicitly queued = user's own, and
  `addToQueue` inserts BEFORE the tail). All fetches go through one shared
  `radioFetchTask` (`ensureRadioFetch`) so a prefetch and the end-of-queue
  advance never race — the advance AWAITS the in-flight fetch instead of
  bailing to a stop, and `merge` re-checks `autoplayEnabled` at append time so
  a fetch that lands after toggle-off appends nothing. `extendQueueWithRadio`
  follows up to several continuation pages before giving up — one page can
  dedupe to nothing (re-seeding a radio returns already-queued songs) while
  the cursor still advances. The toggle is SILENT by request (no toasts —
  songs just appear/disappear at the tail; the unified log still records it).
  **iOS toasts are mirrored in `NowPlayingScreen`** — the `fullScreenCover`
  hides `MobileRoot`'s overlay, so toasts fired from the queue tab (e.g.
  "Playing next") would otherwise be invisible.
- **Diagnostics:** `EncoreCore.Log` — os.Logger, subsystem
  `dev.charlie.encore`, categories player/net; DEBUG builds also mirror to
  stderr. Live device capture:
  `log stream --device --predicate 'subsystem == "dev.charlie.encore"' --info`
  or `xcrun devicectl device process launch --console`. The player lifecycle
  (restore / first-play / engage decision / state / queue advance) is
  instrumented on both platforms.

---

## 6. Feature inventory (DONE & verified unless noted)

Both platforms unless stated:
- Home feed, Explore (macOS), Search (real catalog search via Search tab/top bar)
- Library: Playlists, Songs (all known tracks), Albums, Artists (aggregated
  across likes+playlists), History (macOS), **Podcasts (under Library)**
- Sort + filter (CJK-aware) via shared `LibrarySort`; **full options in every
  Library tab**; per-collection persistence. Playlist detail pages: "Playlist
  Order" + "Recently Added" (reverse-of-position; no per-track date exists), and
  **playlists always open sorted by Artist** (forced, not persisted).
- Album / playlist / artist pages; artist page shows "In your playlists & likes".
  Album pages show track numbers instead of per-row artwork (identical on an
  album) — BOTH platforms (`showsArtwork: !isAlbum`).
- **Podcasts — currently DISABLED behind `PodcastFeature.enabled = false`
  (2026-06-22); see PODCASTS.md for the one-line re-enable + retest checklist.**
  The feature itself: Apple-Podcasts-style pages on BOTH platforms (iOS
  `PodcastScreen`, macOS `PodcastView`) — header, expandable description,
  Recent/Oldest sort, episode rows with date + description + duration + circular
  play. Episodes carry `isEpisode/dateText/details`. **Mark-as-played** per
  episode (check toggle + menu); state in `EncoreCore.PlayedEpisodes`
  (UserDefaults, unit-tested) — played episodes dim + show a PLAYED badge.
- Playback: queue, shuffle, repeat, song radio, **Autoplay** toggle, endless
  auto-radio when the queue ends (continuation-driven — see §5), sleep timer,
  session restore (paused; first play forces a clean load — see §5),
  **playback speed
  0.8–2× + skip 15/30 for podcast episodes** (iOS), **phone-call/Siri audio
  interruption → pause + auto-resume** (iOS; macOS has no AVAudioSession hook)
- Now Playing: immersive, artwork-tinted, content padded below the Dynamic
  Island (iOS); **synced lyrics** (YT timed → LRCLIB → NetEase → Musixmatch →
  YT plain → Genius; user-pickable, persisted); Up Next queue; video mode (macOS)
- Create playlist; right-click/long-press → Add to Playlist / Remove from
  Playlist / Remove from Liked; like/unlike (authoritative state)
- **Edit playlist** (own playlists): rename / description / privacy via an Edit
  button → `PlaylistEditSheet` (`YTM.editPlaylist`). No custom art (unsupported).
- **Discover shelf** on Home (both platforms): cross-language fresh picks
  excluding known + history (`LibraryStore.discover()` + `EncoreCore.Discovery`)
- **iOS performance:** library playlists are prefetched into the disk-backed
  `PageCache` on launch (via `allKnownTracks`) so playlists open instantly;
  larger tap targets across rows/mini-player/cards
- **Output-device picker** (AirPlay/Bluetooth): player-bar button (macOS) +
  now-playing button (iOS)
- **Play counts:** global plays ("102M plays") on artist Top songs + search,
  with a "Plays" sort (default on play-count lists). Personal **Most Played**
  views (macOS sidebar + iOS Library entry) are **ON** as of 2026-07-02
  (`PlayCountsFeature.enabled = true`) with **per-device** counts — no
  cross-device sync yet, accepted as-is. Play RECORDING runs regardless of the
  flag (see BUGS.md). macOS playlist pages also show a personal times-played
  column (`TrackRow.playCount`, snapshotted once per render in
  `CollectionView.trackList`).
- **iOS music videos play as audio** (counterpart swap) so playback survives
  lock (see §5)
- iOS Now Playing: drag-to-dismiss, Song/Lyrics/Queue tabs at bottom; artwork
  is NSCache'd + downsampled on both platforms (scroll perf)
- Media keys + system Now Playing widget (remote play/pause explicit — see §5);
  ⌘K palette, mouse back/forward, Space=play/pause, ⌘R reloads the current
  page (macOS)
- **CarPlay** (iOS): tab bar (Home with Your Playlists + feed, Library) →
  playlist → episodes/tracks → system Now Playing. **Verified working in the
  CarPlay simulator.** Currently DISABLED in shipped Info.plist (see §7).
- iOS app icon; iOS installable on a free Apple ID (see §7); **optional baked-in
  dev cookie auto-signs-in on launch** (see §7)

---

## 7. CarPlay & iOS device install — IMPORTANT current state

To let Charlie install on his iPhone with a **free Apple ID**, the CarPlay
entitlement AND the CarPlay scene declaration are **commented out** in
`iOS/project.yml`:
- The `com.apple.developer.carplay-audio` entitlement can't be provisioned by a
  free/un-granted account → blocks device signing.
- iOS refuses to launch an app that declares a CarPlay scene in Info.plist
  WITHOUT that entitlement.

So both are disabled together. **The CarPlay code (`CarPlay.swift`) is intact
and verified working in the simulator.** To re-enable CarPlay (simulator demo,
or once Apple grants the entitlement for a paid account): uncomment BOTH the
`entitlements:` block and the `CPTemplateApplicationSceneSessionRoleApplication`
block in `project.yml`, regenerate, rebuild. Real cars / TestFlight require the
paid Apple Developer Program + Apple's granted **CarPlay Audio** entitlement
(a separate request form, not self-serve).

**iOS deploy steps for Charlie:** open `EncoreiOS.xcodeproj` in Xcode → select
the `EncoreiOS` target → Signing & Capabilities → pick his Team (free personal
team is fine) → connect iPhone → Run. First run needs Settings → General →
VPN & Device Management → trust. Free-account apps expire after 7 days.

**CLI device build+install** (no Xcode GUI) works if his Apple ID is in Xcode
accounts — team `9272YGK74X`, device id `5A20AF61-E66A-5BE7-AA6C-5C7AFAB438A7`.
Preferred: `Encore/scripts/deploy_ios.sh` (wraps the commands below, retries
the transient developer-disk-image mount failure; override via
`ENCORE_DEVICE_ID`/`ENCORE_TEAM_ID`). Manually:
```bash
cd Encore/iOS && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project EncoreiOS.xcodeproj -scheme EncoreiOS \
  -destination 'platform=iOS,id=5A20AF61-E66A-5BE7-AA6C-5C7AFAB438A7' \
  -derivedDataPath .build_device -allowProvisioningUpdates DEVELOPMENT_TEAM=9272YGK74X build
xcrun devicectl device install app --device 5A20AF61-E66A-5BE7-AA6C-5C7AFAB438A7 \
  .build_device/Build/Products/Debug-iphoneos/EncoreiOS.app
```

**Dev auto-sign-in cookie (SECURITY):** `iOS/Sources/DevCredentials.swift`
holds a YouTube `cookie:` header that `AuthManager.bootstrap` imports on launch
when not already signed in, so reinstalls don't need re-pasting. The file is
**committed EMPTY**; the real cookie is local-only via `git update-index
--skip-worktree …/DevCredentials.swift`. **Never commit/push the cookie** (full
Google account credential) — confirm `git status` is clean before committing. It
expires server-side eventually; refresh by editing the (skip-worktree'd) file.

---

## 8. Known risks / unverified

- iOS app-icon **springboard render** not visually confirmed (compiles into the
  bundle correctly; a duplicate stale "Encore" icon may linger in the sim — long-press delete it).
- Hidden 2×2px WKWebView keeping audio alive while parked; video-mode
  re-parenting of the shared web view (macOS).
- Musixmatch token API is rate-limited (Auto mode hides this; pinning
  Musixmatch may come up empty).
- Disk-cached pages can show stale contents for a second after an edit made
  outside Encore, until the background refresh lands.

---

## 9. Queued features

Both previously-queued items **shipped 2026-06-15**:
1. **Discovery** — client-side "Discover · Fresh for you" shelf on Home (both
   platforms). `LibraryStore.discover()` seeds radios (`YTM.discoverPool`) from a
   sample of `allKnownTracks()`, excludes known + `FEmusic_history`, and biases
   to the opposite language of the user's taste via `EncoreCore.Discovery`
   (`curate` is pure + unit-tested; `CJK.hasHan`). Possible future polish:
   genre/mood-anchored seeds, a dedicated Discover route, "fans also like" shelves.
2. **Edit playlist** — rename / description / privacy via `YTM.editPlaylist`
   (`browse/edit_playlist`), surfaced by an Edit button on the playlist page →
   `PlaylistEditSheet` (iOS + macOS). Custom playlist art was intentionally
   **omitted**: YT Music auto-generates it for regular playlists (only uploads
   have editable art, via a flow ytmusicapi doesn't cover).

No queued features remain.

---

## 10. Persistent memory

There is an agent memory dir for this project at
`/Users/charlie/.claude/projects/-Users-charlie-Documents-9-YTMusic/memory/`
with `MEMORY.md` index + notes (git workflow, project, known risks, iOS device
deploy). Keep it updated; it loads each session.

---

## 11. Recommended next-agent workflow

1. Read this file + `git log --oneline -20` to see recent work.
2. For an API/data bug → `swift run encore-smoke` first.
3. Make the change in `EncoreCore` (shared) if it's logic; then wire UI in BOTH
   `Encore/macOS/` and `Encore/iOS/Sources/` for parity — Charlie
   expects feature parity and notices when platforms differ.
4. Build (`./scripts/build_app.sh` for macOS; xcodegen+xcodebuild for iOS),
   verify, then **commit + push** (§4).
5. Keep responses tight; act when you have enough info; don't burn tokens
   re-verifying things that compiled and are low-risk.
