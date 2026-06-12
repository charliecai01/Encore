# Encore — a better YouTube Music for Mac

A native macOS client for YouTube Music that replaces Google's interface with
the best ideas from Spotify, Apple Music, and QQ Music/NetEase — powered by
your own YouTube Music Premium account.

![platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue) ![swift](https://img.shields.io/badge/Swift-6-orange)

## What it borrows, from where

| Inspiration | What Encore took |
|---|---|
| **Spotify** | Persistent sidebar + bottom player bar, fast hover-to-play cards, queue panel, ⌘K quick search |
| **Apple Music** | Immersive now-playing screen, artwork-tinted adaptive colors, clean typography |
| **QQ Music / NetEase** | Karaoke-style synced lyrics, front and center — tap a line to seek |
| **pear-desktop** (the renamed youtube-music Electron app) | Driving the real `music.youtube.com` player via injected JS, so every track plays at Premium quality on your account |
| **YouTube Music** | The catalog, your library, mixes, radio, and recommendation engine — via the InnerTube API |

## Running it

```bash
cd Encore
./scripts/build_app.sh
open build/Encore.app
```

Requires macOS 15+ and the Xcode Command Line Tools (`swift`). No other dependencies.

On first launch, click **Sign in** (sidebar or the account icon, top right) and
log into your Google account in the embedded sheet. That unlocks your home
feed mixes, library, history, and ad-free Premium playback. You can use search
and playback without signing in too.

## Features

- **Home / Explore** — your personalized shelves (Supermixes, quick picks, new releases)
- **Search** — ⌘K palette with live suggestions, or the top search bar; filter by songs/albums/artists/playlists/videos
- **Library** — playlists, liked songs, albums, artists, and listening history
- **Full playback** — queue management (play next / add to queue / reorder-lite), shuffle, repeat one/all, song radio, auto-radio when the queue runs out
- **Synced lyrics** — YouTube's own timed lyrics when available (fetched via the Android client), falling back to LRCLIB
- **Now Playing** — blurred-artwork immersive view with synced lyrics or up-next, plus a video mode for music videos
- **Native niceties** — media keys, menu-bar Now Playing widget, Space to play/pause, ⌘←/⌘→ prev/next, dynamic accent colors from artwork

## Architecture

```
Encore/
├── Sources/EncoreCore/      # platform-agnostic — shared with the future iOS app
│   ├── InnerTube.swift      # YouTube Music internal API client (SAPISID cookie auth)
│   ├── Parsers.swift        # resilient recursive parsers for InnerTube responses
│   ├── YTM.swift            # high-level API: search/browse/library/queue/lyrics
│   ├── LRCLib.swift         # synced-lyrics fallback provider
│   └── Models.swift, JSONValue.swift
├── Sources/Encore/          # macOS SwiftUI app
│   ├── PlayerEngine.swift   # hidden WKWebView driving music.youtube.com's player
│   ├── AuthManager.swift    # in-app Google sign-in (WKWebView cookie store)
│   └── …views
└── Sources/encore-smoke/    # live API smoke test: swift run encore-smoke
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

## iOS (next)

`EncoreCore` is platform-agnostic by design. The iOS app needs:
1. Full Xcode installed (the iOS SDK isn't in Command Line Tools)
2. An iOS app target reusing `EncoreCore` + `PlayerEngine` (WKWebView works the
   same on iOS; add `allowsInlineMediaPlayback`)
3. Rebuilt SwiftUI layouts (tab bar instead of sidebar, sheet-style now playing)

## Disclaimers

Personal-use project. Unofficial — not affiliated with Google/YouTube. It uses
your own Premium account through Google's own web player; no downloading, no
stream ripping, no ad circumvention.
