# Known bugs / disabled features

## Podcasts — DISABLED (2026-06-22)

The podcast feature is disabled again, now behind a single flag
(`PodcastFeature.enabled`). See **[PODCASTS.md](PODCASTS.md)** for the full
feature guide and the one-line re-enable steps.

## Most Played (personal play counts) — UI DISABLED (2026-06-23)

The "Most Played" view (personal per-song play counts) is hidden behind
`PlayCountsFeature.enabled` (default `false`) — flip to `true` and rebuild to
restore the iOS Library entry + macOS sidebar item. It's off because the counts
are per-device and there's no cross-device sync yet (iCloud needs a paid Apple
Developer account). Play **recording keeps running** while it's off, so the
history is ready on re-enable. The *global* play count shown on artist Top songs
/ search (`Track.playsText`) is a separate feature and stays on.
