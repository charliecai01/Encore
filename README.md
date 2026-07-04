# Encore — a better YouTube Music for Mac & iPhone

A native **macOS + iOS** client for YouTube Music that replaces Google's
interface with the best ideas from Spotify, Apple Music, and QQ Music/NetEase —
powered by your own YouTube Music Premium account. Both apps share one
platform-agnostic core (`EncoreCore`).

![platform](https://img.shields.io/badge/platform-macOS%2015%2B%20%7C%20iOS%2017%2B-blue) ![swift](https://img.shields.io/badge/Swift-6-orange)

## What it borrows, from where

| Inspiration | What Encore took |
|---|---|
| **Spotify** | Persistent sidebar + bottom player bar, fast hover-to-play cards, queue panel, ⌘K quick search |
| **Apple Music** | Immersive now-playing screen, artwork-tinted adaptive colors, clean typography |
| **QQ Music / NetEase** | Karaoke-style synced lyrics, front and center — tap a line to seek |
| **pear-desktop** (the renamed youtube-music Electron app) | Driving the real `music.youtube.com` player via injected JS, so every track plays at Premium quality on your account |
| **YouTube Music** | The catalog, your library, mixes, radio, and recommendation engine — via the InnerTube API |

## Running it

**macOS:**
```bash
cd Encore
./scripts/build_app.sh
open build/Encore.app
```
Requires macOS 15+ and the Xcode Command Line Tools (`swift`).

**iOS** (needs full Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen)):
```bash
cd Encore/iOS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate        # regenerate after adding/removing source files
xcodebuild -project EncoreiOS.xcodeproj -scheme EncoreiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build_ios build
```
Open `EncoreiOS.xcodeproj` in Xcode and Run to deploy to a device (pick your
signing team; a free personal Apple ID works — apps then expire after 7 days).

**Tests:** `cd Encore && swift test` runs the shared-core unit tests.

On first launch, click **Sign in** (sidebar / account icon on macOS, account
icon on iOS) and log into your Google account in the embedded sheet — or paste a
`cookie:` header via **Paste Cookies**. That unlocks your home mixes, library,
history, and ad-free Premium playback. Search and playback work without signing
in too.

## Features

- **Home / Explore** — your personalized shelves (Supermixes, quick picks, new releases)
- **Search** — ⌘K palette with live suggestions, or the top search bar; filter by songs/albums/artists/playlists/videos
- **Library** — playlists, liked songs, albums, artists, and listening history; CJK-aware sort + filter, full sort options in every tab
- **Full playback** — queue management (play next / add to queue / reorder-lite), shuffle, repeat one/all, song radio, endless Autoplay radio when the queue runs out, sleep timer, session restore
- **Play counts** — global play counts on artist top songs and search, with a "Plays" sort; plus a personal **Most Played** view and a times-played column on playlists (macOS) — counts are per-device, no cross-device sync yet
- **Podcasts** *(currently disabled behind `PodcastFeature.enabled` — see [PODCASTS.md](PODCASTS.md))* — Apple-Podcasts-style show pages with episode dates, descriptions, and durations; variable playback speed (0.8–2×) and skip 15/30 for episodes (iOS)
- **Synced lyrics** — YouTube's own timed lyrics when available (fetched via the Android client), falling back to LRCLIB / NetEase / Musixmatch / Genius
- **Now Playing** — blurred-artwork immersive view with synced lyrics or up-next; podcasts get an Apple-Podcasts-style player (iOS screen + macOS bar) with speed, ±15/30s, resume, and progress bars
- **Native niceties** — media keys, system/lock-screen Now Playing widget, **AirPlay/output-device picker**, **CarPlay** (iOS), **phone-call/Siri interruption handling** (iOS), Space to play/pause, ⌘←/⌘→ prev/next, ⌘R refresh (macOS), dynamic accent colors from artwork

## Architecture

```
Encore/
├── Sources/EncoreCore/      # platform-agnostic core — SHARED by both apps
│   ├── InnerTube.swift      # YouTube Music internal API client (SAPISID cookie auth)
│   ├── Parsers.swift        # resilient recursive parsers for InnerTube responses
│   ├── YTM.swift            # high-level API: search/browse/library/queue/lyrics/podcasts
│   ├── LibrarySort.swift    # shared, unit-tested sort/filter for tracks & cards
│   ├── LRCLib.swift         # synced-lyrics fallback provider
│   └── Models.swift, JSONValue.swift, CJK.swift
├── Sources/encore-smoke/    # live API smoke test: swift run encore-smoke
├── macOS/                   # macOS SwiftUI app (SwiftPM target "Encore")
│   ├── PlayerEngine.swift   # hidden WKWebView driving music.youtube.com's player
│   ├── AuthManager.swift    # in-app Google sign-in (WKWebView cookie store)
│   └── …views
├── Tests/EncoreCoreTests/   # offline unit tests: swift test
└── iOS/                     # iOS app (XcodeGen; project/scheme named EncoreiOS)
    └── Sources/             # MobilePlayer, MobileScreens, NowPlayingScreen, CarPlay…
```

**How playback works:** a hidden WKWebView loads the real music.youtube.com
signed into your account. An injected script exposes `#movie_player` controls
(load/play/pause/seek/volume) over the script-message bridge, and reports
state/time back 4×/second. Native UI everywhere; Google's player only does the
streaming. This is the same approach pear-desktop uses, which means no embed
restrictions and your plays count toward your recommendations.

**API:** `EncoreCore` talks to the InnerTube endpoints (`browse`, `search`,
`next`, `like`) directly — the Swift equivalent of
[ytmusicapi](https://github.com/sigma67/ytmusicapi). Auth reuses the cookies
from the in-app sign-in (SAPISID hash), so there's no separate header-pasting
setup.

## iOS

Shipped. The iOS app reuses `EncoreCore` and ports the player engine to UIKit
(`MobilePlayer.swift`), with a tab-bar layout, sheet-style Now Playing,
CarPlay, podcast playback speed, and phone-call interruption handling. It's a
separate Xcode project generated by XcodeGen (`project.yml`) — **re-run
`xcodegen generate` after adding or removing source files**. CarPlay is built
and verified in the simulator but disabled in the shipped build so the app can
sign with a free Apple ID (re-enable via the `project.yml` entitlement +
scene blocks). See [HANDOFF.md](HANDOFF.md) §7 for the full iOS build/deploy
details, or run `Encore/scripts/deploy_ios.sh` for a one-command device deploy.

## Disclaimers

Personal-use project. Unofficial — not affiliated with Google/YouTube. It uses
your own Premium account through Google's own web player; no downloading, no
stream ripping, no ad circumvention.
