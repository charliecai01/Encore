# Known bugs / disabled features

## Podcasts — DISABLED (2026-06-22)

The podcast feature is disabled again, now behind a single flag
(`PodcastFeature.enabled`). See **[PODCASTS.md](PODCASTS.md)** for the full
feature guide and the one-line re-enable steps.

## Most Played (personal play counts) — ENABLED, per-device (2026-07-02)

The "Most Played" view (personal per-song play counts) is on
(`PlayCountsFeature.enabled = true`): iOS Library entry + macOS sidebar item.
Counts are **per-device** — there's still no cross-device sync (iCloud needs a
paid Apple Developer account), and that's accepted as the current behavior; each
install tallies its own plays. Play **recording runs regardless of the flag**,
so history accumulates either way. The *global* play count shown on artist Top
songs / search (`Track.playsText`) is a separate always-on feature.

Set the flag back to `false` and rebuild to hide the UI again.
