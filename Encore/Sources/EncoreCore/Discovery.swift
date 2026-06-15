import Foundation

/// Client-side "Discover" curation. Google's home feed just echoes the user's
/// daily rotation, so we build a fresh shelf from radio pools and bias it toward
/// the *other* language than the user's dominant taste (e.g. a mostly-Chinese
/// listener gets English picks of a similar vibe, since radios stay on-genre).
public enum Discovery {

    public static func isCJK(_ track: Track) -> Bool {
        CJK.hasHan(track.title) || CJK.hasHan(track.artistLine)
    }

    /// Fraction of tracks that are CJK — used to decide the discovery language.
    public static func cjkFraction(_ tracks: [Track]) -> Double {
        guard !tracks.isEmpty else { return 0 }
        return Double(tracks.filter(isCJK).count) / Double(tracks.count)
    }

    /// From a radio candidate pool: drop excluded ids + episodes, dedupe, and
    /// prefer the cross-language subset. Falls back to all fresh picks if the
    /// preferred-language subset is too thin to fill a shelf.
    public static func curate(candidates: [Track], exclude: Set<String>,
                              preferNonCJK: Bool, limit: Int = 40) -> [Track] {
        var seen = Set<String>()
        let fresh = candidates.filter { t in
            !t.videoId.isEmpty && !t.isEpisode
                && !exclude.contains(t.videoId) && seen.insert(t.videoId).inserted
        }
        let preferred = fresh.filter { preferNonCJK ? !isCJK($0) : isCJK($0) }
        let chosen = preferred.count >= min(8, limit) ? preferred : fresh
        return Array(chosen.prefix(limit))
    }
}
