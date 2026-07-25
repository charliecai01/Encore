# Known bugs / disabled features

## Equalizer — DISABLED (2026-07-23), breaks playback in WKWebView

`Equalizer.featureEnabled = false`. **Symptom:** the first song plays, every
song after it is silent (reported on iOS; macOS uses the identical mechanism
and is presumed affected).

**Cause:** the EQ tapped the site's `<video>` with
`createMediaElementSource`, which permanently reroutes that element's audio
through the Web Audio graph. In WKWebView the source node stops producing
output once the element loads a *different* track — so track 2 onward is
silent. `createMediaElementSource` is **once-per-element and irreversible**
(a second call throws), so nothing in-page can restore direct audio; only
never tapping the element, or a full page reload, works.

While the flag is `false` the engines never call `__encore.eq(...)` at all —
the graph is never built and the audio path is untouched — and the EQ UI is
hidden on both platforms. The JS graph, the `Equalizer` model (9 unit tests),
and both UIs remain intact behind the flag.

**If you revive it,** the element tap is a dead end in WKWebView; a viable EQ
would need a different audio path entirely (e.g. routing playback through a
native AVAudioEngine, which this architecture doesn't have since Google's
player owns the stream). Verify any attempt by playing **through a track
change**, not just one song — that's what the original testing missed.

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
