import Foundation

/// Builds queues that skip the tracks YouTube has already told us it won't play
/// (`Track.isUnavailable`, from the GREY_OUT display policy).
///
/// Without this, a run of greyed rows inside a playlist plays as a burst of
/// error-150-then-skip — three in ~1.2s in Charlie's "Favorite Songs" — which
/// reads as the player jumping around on its own. Filtering at queue-build time
/// means auto-advance never walks into one.
public enum PlayableQueue {

    /// Drops unavailable tracks and remaps the start index so the user still
    /// starts where they tapped — or, if they tapped a greyed row, at the next
    /// playable track after it (falling back to the last playable one before).
    /// Returns an empty queue when nothing is playable, so callers can say so
    /// rather than starting silence.
    public static func build(_ tracks: [Track], startAt: Int) -> (tracks: [Track], startAt: Int) {
        var kept: [Track] = []
        var originalIndex: [Int] = []
        for (i, t) in tracks.enumerated() where !t.isUnavailable {
            kept.append(t)
            originalIndex.append(i)
        }
        guard !kept.isEmpty else { return ([], 0) }
        let target = tracks.indices.contains(startAt) ? startAt : 0
        // First surviving track at or after the tapped row; if the tail is all
        // unavailable, the last surviving one before it.
        let idx = originalIndex.firstIndex { $0 >= target } ?? (kept.count - 1)
        return (kept, idx)
    }
}
