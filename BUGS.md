# Known bugs / disabled features

## Podcasts — ENABLED (2026-07-03)

Re-enabled with the Apple-Podcasts-style experience: dedicated iOS Now Playing
screen (speed/skip/video/mark-played), resume-where-you-left-off, and episode
progress bars. Still gated behind `PodcastFeature.enabled` — see
**[PODCASTS.md](PODCASTS.md)** for the feature guide and disable steps.

## Most Played (personal play counts) — ENABLED, per-device (2026-07-02)

The "Most Played" view (personal per-song play counts) is on
(`PlayCountsFeature.enabled = true`): iOS Library entry + macOS sidebar item.
Counts are **per-device** — there's still no cross-device sync (iCloud needs a
paid Apple Developer account), and that's accepted as the current behavior; each
install tallies its own plays. Play **recording runs regardless of the flag**,
so history accumulates either way. The *global* play count shown on artist Top
songs / search (`Track.playsText`) is a separate always-on feature.

Set the flag back to `false` and rebuild to hide the UI again.
