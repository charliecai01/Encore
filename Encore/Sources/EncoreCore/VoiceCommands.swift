import Foundation

/// The decisions behind the Siri / Shortcuts commands ("Play my favorites in
/// Encore", "Play <playlist> in Encore"). Both apps' App Intents are thin glue
/// over these, so which playlist a spoken name resolves to can't drift
/// between macOS and iOS — the same reason `LibrarySort` exists.
public enum VoiceCommands {

    /// Titles (prefixes, case-insensitive) of the playlist "my favorites"
    /// means. "Favorite Songs" was renamed to "Fav Songs" by 2026-10-15; both
    /// are listed so either spelling resolves. Kept in step with the first
    /// entries of `HomeSections.pinnedPlaylistTitles`.
    public static let favoritesTitles = ["Fav Songs", "Favorite Songs"]

    /// The favorites playlist among `playlists`, or nil if there isn't one
    /// (the intent then falls back to the liked-songs library).
    public static func favoritesPlaylist(in playlists: [CardItem]) -> CardItem? {
        for stem in favoritesTitles {
            if let hit = playlists.first(where: { $0.title.lowercased().hasPrefix(stem.lowercased()) }) {
                return hit
            }
        }
        return nil
    }

    /// The playlist a spoken/typed name refers to. Siri transcribes titles
    /// loosely ("R and B by sonnet", "my road trip playlist"), so matching is
    /// on normalized words: exact, then prefix, then contains, then the most
    /// shared words. Returns nil when nothing shares a word with the query.
    public static func bestPlaylistMatch(for query: String, in playlists: [CardItem]) -> CardItem? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let candidates = playlists.map { ($0, normalize($0.title)) }.filter { !$0.1.isEmpty }
        if let hit = candidates.first(where: { $0.1 == q }) { return hit.0 }
        if let hit = candidates.first(where: { $0.1.hasPrefix(q) }) { return hit.0 }
        if let hit = candidates.first(where: { $0.1.contains(q) || q.contains($0.1) }) { return hit.0 }
        let qWords = Set(q.split(separator: " "))
        let scored = candidates
            .map { ($0.0, Set($0.1.split(separator: " ")).intersection(qWords).count) }
            .filter { $0.1 > 0 }
        // max(by:) returns the LAST max on ties; reverse so the first
        // (server-order) playlist wins instead.
        return scored.reversed().max(by: { $0.1 < $1.1 })?.0
    }

    /// Extra spoken names per playlist id, handed to Siri as entity synonyms.
    /// Siri only fills "Play <playlist> in Encore" with a registered title or
    /// synonym — "play R&B in Encore" against "R&B by Sonnet" otherwise falls
    /// through to Siri's built-in media domain, which Encore doesn't serve
    /// ("the app doesn't support that request"). Aliases: the title before
    /// " by …" / " - …" / " (…)", and "&" spelled out as "and". An alias that
    /// is another playlist's name, or that two playlists would share, is
    /// dropped so it can't hijack the wrong playlist.
    public static func spokenAliases(for playlists: [CardItem]) -> [String: [String]] {
        func pid(_ card: CardItem) -> String { card.playlistId ?? card.browseId ?? card.id }
        func stems(_ title: String) -> [String] {
            var out = [title]
            for sep in [" by ", " - ", " – ", " ("] {
                if let r = title.range(of: sep, options: .caseInsensitive), r.lowerBound > title.startIndex {
                    out.append(String(title[..<r.lowerBound]))
                }
            }
            for s in out where s.contains("&") {
                out.append(s.replacingOccurrences(of: "&", with: " and ")
                    .split(separator: " ").joined(separator: " "))
            }
            return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let titles = Set(playlists.map { normalize($0.title) })
        var claims: [String: Set<String>] = [:]   // normalized alias → playlist ids
        var aliases: [String: [String]] = [:]
        for card in playlists {
            let own = normalize(card.title)
            // Dedupe on the spelled form: "R&B" and "R and B" normalize alike
            // but are different things for Siri to hear.
            var seen: Set<String> = [card.title.lowercased()]
            for alias in stems(card.title) {
                let key = normalize(alias)
                guard !key.isEmpty, seen.insert(alias.lowercased()).inserted,
                      key == own || !titles.contains(key) else { continue }
                claims[key, default: []].insert(pid(card))
                aliases[pid(card), default: []].append(alias)
            }
        }
        return aliases.mapValues { $0.filter { claims[normalize($0)]?.count == 1 } }
            .filter { !$0.value.isEmpty }
    }

    /// Lowercased, Han-simplified, accent-free words with "&" spelled out and
    /// filler ("my", "the", "playlist") dropped.
    static func normalize(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .matchNormalized
        let filler: Set<Substring> = ["my", "the", "playlist", "a"]
        let words = folded
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .filter { !filler.contains($0) }
        return words.joined(separator: " ")
    }
}
