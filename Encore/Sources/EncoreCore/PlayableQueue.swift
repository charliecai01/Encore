import Foundation

/// Builds queues that skip the tracks YouTube has already told us it won't play
/// (`Track.isUnavailable`, from the GREY_OUT display policy), and collapse
/// duplicate library entries that would otherwise play back-to-back.
///
/// Without the first, a run of greyed rows inside a playlist plays as a burst
/// of error-150-then-skip — three in ~1.2s in Charlie's "Favorite Songs" —
/// which reads as the player jumping around on its own. Filtering at
/// queue-build time means auto-advance never walks into one.
///
/// The second exists because "Favorite Songs" has two separate entries for
/// 他不慣被愛 by 衛蘭 — same song, different videoIds (added twice at
/// different times, or re-liked). Both platforms open playlists sorted by
/// artist by default, which put the pair adjacent; the engine then played one
/// straight into the other, which is exactly what "plays the same song twice
/// before the next one" sounds like — the engine wasn't malfunctioning, it was
/// following a queue that itself had the song twice.
public enum PlayableQueue {

    /// Drops unavailable tracks and collapses adjacent EXACT duplicates (same
    /// title AND same artistLine — never fuzzy, so a genuinely different
    /// recording like "(Ballad Version)" is untouched), then remaps the start
    /// index so the user still starts where they tapped. Tapping a row never
    /// drops it, even if it duplicates its neighbor — only the OTHER copy in
    /// the pair collapses. If the tapped row itself was unavailable, playback
    /// starts at the next playable track after it (or the last one before, if
    /// the tail is all unavailable). Returns an empty queue when nothing is
    /// playable, so callers can say so rather than starting silence.
    public static func build(_ tracks: [Track], startAt: Int) -> (tracks: [Track], startAt: Int) {
        let target = tracks.indices.contains(startAt) ? startAt : 0

        var kept: [Track] = []
        var keptOriginalIndex: [Int] = []
        for (i, t) in tracks.enumerated() where !t.isUnavailable {
            kept.append(t)
            keptOriginalIndex.append(i)
        }
        guard !kept.isEmpty else { return ([], 0) }

        var deduped: [Track] = []
        var dedupedOriginalIndex: [Int] = []
        for (i, t) in kept.enumerated() {
            let isTapped = keptOriginalIndex[i] == target
            if !isTapped, let last = deduped.last,
               last.title == t.title, last.artistLine == t.artistLine {
                continue
            }
            deduped.append(t)
            dedupedOriginalIndex.append(keptOriginalIndex[i])
        }

        // First surviving track at or after the tapped row; if the tail is all
        // unavailable/deduped away, the last surviving one before it.
        let idx = dedupedOriginalIndex.firstIndex { $0 >= target } ?? (deduped.count - 1)
        return (deduped, idx)
    }
}
