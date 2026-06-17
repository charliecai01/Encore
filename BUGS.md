# Known bugs / disabled features

## Podcasts — DISABLED (2026-06-16)

The podcast feature (browsing podcast shows, episode lists, and episode
playback) was too buggy to ship, so it is **disabled in both the macOS and iOS
apps**. The UI entry points are hidden and podcast navigation is a no-op, but
the underlying code is left in place (commented out or kept unreachable) so it
can be reimplemented later.

### What was disabled

**macOS**
- `Encore/macOS/Nav.swift`
  - `LibraryTab.visible` excludes `.podcasts`, so the "Podcasts" item is hidden
    from the sidebar. The enum `case podcasts` is kept so switches stay
    exhaustive.
  - `Nav.open(_:)` — the `.podcast` card case is a no-op (navigation commented out).
  - `decode(_:)` — a saved `podcastShow` route no longer restores (returns `nil`).
- `Encore/macOS/SidebarView.swift` — iterates `LibraryTab.visible`.
- Still present but unreachable: `PodcastView`, `RootView`'s `.podcastShow`
  route handler, `CollectionView`'s `.podcast` kind, `LibraryView`'s
  `.podcasts` loader.

**iOS**
- `Encore/iOS/Sources/MobileServices.swift`
  - `LibraryTab.visible` excludes `.podcasts` (Library segmented control).
  - `Nav.open(_:)` — the `.podcast` card case is a no-op.
- `Encore/iOS/Sources/MobileScreens.swift` — Library picker iterates
  `LibraryTab.visible`.
- `Encore/iOS/Sources/NowPlayingScreen.swift` — the episode/podcast player UI
  (variable speed + ±15/30s skip controls, the "podcast play screen") is
  commented out; playback always uses the standard song transport. The
  `speedButton`/`rateLabel` helpers are commented out with it.
- Still present but unreachable: `PodcastScreen`, `EpisodeRow`,
  `MobileRoot`'s `.podcastShow` route, episode-specific remote commands in
  `MobilePlayer.swift`.

### Not touched (intentionally)
- `EncoreCore` parsing/models (`podcastShow`, `libraryPodcasts`, `Track.isEpisode`,
  `PlayedEpisodes`, podcast `CardItem` kind) — shared library code, still
  exercised by tests and needed when the feature returns.
- Podcast cards may still appear in Home/Explore/search shelves; tapping them
  is a no-op for now.

### To re-enable
Re-add `.podcasts` to `LibraryTab.visible` (both apps), restore the `.podcast`
cases in both `Nav.open(_:)` and the macOS `decode(_:)`, and un-comment the iOS
episode player UI in `NowPlayingScreen.swift`. Then fix the underlying podcast
playback/screen bugs.
