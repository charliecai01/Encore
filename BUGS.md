# Known bugs / disabled features

## Podcasts — DISABLED (2026-07-13)

Turned off at Charlie's request (`PodcastFeature.enabled = false`). The full
Apple-Podcasts-style experience (dedicated iOS Now Playing screen, macOS bar
transport, resume, progress bars, Home shelf, pinned shows) remains intact
behind the flag — flipping it to `true` and rebuilding restores everything.
The two playback incidents that motivated this were general engine bugs, both
since fixed (episode-radio seeding; unplayable-track reload-looping). See
**[PODCASTS.md](PODCASTS.md)** for the feature guide and the video known-bug.

## Most Played (personal play counts) — ENABLED, per-device (2026-07-02)

The "Most Played" view (personal per-song play counts) is on
(`PlayCountsFeature.enabled = true`): iOS Library entry + macOS sidebar item.
Counts are **per-device** — there's still no cross-device sync (iCloud needs a
paid Apple Developer account), and that's accepted as the current behavior; each
install tallies its own plays. Play **recording runs regardless of the flag**,
so history accumulates either way. The *global* play count shown on artist Top
songs / search (`Track.playsText`) is a separate always-on feature.

Set the flag back to `false` and rebuild to hide the UI again.
