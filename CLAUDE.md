# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Encore — a native **macOS + iOS** YouTube Music client (Swift 6) that replaces
Google's UI with a Spotify/Apple-Music/QQ-Music-inspired interface, using the
user's own YT Music Premium account. Both apps share one platform-agnostic
core, `EncoreCore`. Personal-use project, unofficial, not affiliated with
Google/YouTube.

Full agent-oriented context (repo layout, architecture, gotchas, feature
inventory, CJK naming system, maintenance tools) lives in
[HANDOFF.md](HANDOFF.md) — read it before non-trivial work; it is the single
source of truth and more detailed than this file. [BUGS.md](BUGS.md) tracks
disabled features and known bugs (Equalizer, Podcasts). [PODCASTS.md](PODCASTS.md)
covers the podcast feature guide.

## Commands

**macOS build (builds + installs to /Applications, relaunches if running):**
```bash
cd Encore && ./scripts/build_app.sh
```

**iOS build (needs full Xcode + XcodeGen; re-run xcodegen after adding/removing source files):**
```bash
cd Encore/iOS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project EncoreiOS.xcodeproj -scheme EncoreiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build_ios build
```
Note: the target/scheme is `EncoreiOS`, not `Encore` (the macOS package
executable target is `Encore` — sharing the name pulls AppKit sources into the
iOS build). Never build the simulator app with `CODE_SIGNING_ALLOWED=NO` — it
fails to launch.

**iOS device deploy (one command):**
```bash
Encore/scripts/deploy_ios.sh
```
Wraps device build+install, retries the transient developer-disk-image mount
failure. Team `9272YGK74X`. Override via `ENCORE_DEVICE_ID`/`ENCORE_TEAM_ID`.

**Unit tests (shared core, covers both apps' logic):**
```bash
cd Encore && swift test
```
Run a single test: `swift test --filter <TestClassName>` or
`swift test --filter <TestClassName>/<testMethodName>`.

**Live API smoke test (fast, no UI, unauthenticated — run FIRST for a reported data/parsing bug):**
```bash
cd Encore && swift run encore-smoke
```

**App-wide health sweep (opt-in; every screen's live API call, prints `SUSPECT` for anomalies):**
```bash
ENCORE_HEALTH_SWEEP=1 swift test --filter HealthSweepTests
```
Needs a signed-in test cookie (`ENCORE_TEST_COOKIE` env var or the local
skip-worktree'd `iOS/Sources/DevCredentials.swift`); skips cleanly without one.

**Playlist maintenance tool** (rotates the "R&B by Sonnet5" generated playlist — see HANDOFF.md §13):
```bash
cd Encore && swift run encore-playlist-tool [--dry-run|--force|--check=<playlistId>|--list-playlists]
```

## Architecture

```
Encore/
├── Package.swift               # SwiftPM: EncoreCore (library product), Encore (macOS exe),
│                                #   encore-smoke, encore-playlist-tool, EncoreCoreTests
├── Sources/EncoreCore/          # platform-agnostic core (Foundation + CryptoKit only) — SHARED brain
│   ├── InnerTube.swift          # low-level YouTube InnerTube API client + SAPISID auth
│   ├── YTM.swift                # high-level API: search/browse/library/queue/lyrics/podcasts/playlist-edit
│   ├── Parsers.swift            # resilient recursive parsers for InnerTube JSON (JSONValue.findAll/findFirst)
│   ├── LibrarySort.swift        # shared, unit-tested sort/filter for tracks & cards — both apps delegate here
│   ├── NativeNames.swift        # CJK artist/title display-name normalization (see HANDOFF.md §12)
│   ├── StallPolicy.swift        # buffering-aware stall/reload backoff policy (unit-tested)
│   ├── PlayableQueue.swift      # drops unavailable (greyed-out) tracks at queue-build time
│   └── Log.swift                # os.Logger facade, subsystem dev.charlie.encore (DEBUG also → stderr)
├── macOS/                       # macOS SwiftUI/AppKit app — SwiftPM target "Encore"
│   ├── PlayerEngine.swift       # hidden WKWebView driving music.youtube.com's player
│   └── AuthManager.swift        # in-app Google sign-in (WKWebView cookie store)
├── iOS/                         # iOS app — separate Xcode project (XcodeGen; project/scheme "EncoreiOS")
│   └── Sources/
│       ├── MobilePlayer*.swift  # iOS PlayerEngine port (UIKit); speed/skip/call-interruption handling
│       └── MobileServices.swift # Theme, DiskCache, PageCache, AuthManager, LibraryStore, Nav
└── Tests/EncoreCoreTests/       # XCTest for the shared core — covers BOTH apps' logic
```

**Core principle:** `EncoreCore` is the shared brain for both platforms and
must stay exposed as a `.library` **product** (not just a target) in
`Package.swift` so the external iOS Xcode project can link it. When changing
shared logic (sorting, parsing, queue behavior, naming), change it in
`EncoreCore` once and add/extend a test there — never fork the logic per
platform.

**How playback works:** a hidden `WKWebView` loads the real
`music.youtube.com` signed into the user's account. An injected JS controller
(`window.__encore`) drives the site's `#movie_player` (load/play/pause/seek/
volume) and reports state/time back over a script-message bridge 4×/sec plus
an event-driven `onStateChange` hook. Everything else (queue, shuffle, radio,
lyrics, media keys, now-playing UI) is native. Because it's the real site,
Premium quality applies and plays count toward recommendations. This is the
same technique pear-desktop (renamed youtube-music Electron app) uses.

**API:** `EncoreCore` talks directly to InnerTube endpoints (`browse`,
`search`, `next`, `like`) — a Swift reimplementation of the relevant parts of
[ytmusicapi](https://github.com/sigma67/ytmusicapi). Auth reuses cookies from
the in-app sign-in (SAPISID hash `Authorization` header); there's no separate
header-pasting setup for normal use. Parsers deliberately search the JSON tree
recursively rather than asserting exact shapes, so minor YouTube layout
changes degrade gracefully instead of crashing — when a page breaks, run
`encore-smoke` first to tell an API/parse problem from a UI problem.

**Feature parity requirement:** shared logic goes in `EncoreCore`; UI changes
must be wired in both `Encore/macOS/` and `Encore/iOS/Sources/` — this is a
two-platform app and features are expected to match across both.

## Working in this repo — key constraints

- **Read [HANDOFF.md](HANDOFF.md) §5 ("Hard-won gotchas") before touching
  playback, session restore, sleep timer, CJK naming, autoplay/radio, or the
  WKWebView bridge** — most of that section documents subtle bugs that were
  already fixed once and describes exactly how not to reintroduce them
  (e.g. sleep-timer resume races, WKWebView content-process death recovery,
  site-autoplay hijacking track transitions, stall-policy buffering awareness).
- The **Equalizer is intentionally disabled** (`Equalizer.featureEnabled =
  false`) — tapping the page's `<video>` element for Web Audio permanently and
  irreversibly routes it, and goes silent from the second track onward in
  WKWebView. Do not re-enable without solving that; see BUGS.md.
- **Podcasts are intentionally disabled** (`PodcastFeature.enabled = false`,
  Charlie's call) — the full feature remains implemented behind the flag.
- After adding/removing a `.swift` file under `iOS/Sources`, **re-run
  `xcodegen generate`** or the build fails to find the new file.
- `.build_device/` and `DevCredentials.swift`'s real cookie value are never
  committed (the latter is skip-worktree'd locally) — confirm `git status` is
  clean of credential material before committing.
