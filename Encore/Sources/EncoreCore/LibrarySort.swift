import Foundation

/// Matching for the artist page's "In your playlists & likes" section: does a
/// library track belong to the artist being viewed?
///
/// Two arms:
/// - **id**: any of the track's artist refs equals the page's browse id
///   (`UC…` channel id; an `MPLA…` alias is normalized first).
/// - **name**: artist pages are now often titled with COMBINED names
///   ("陶喆 - David Tao"), which the old `artistLine.contains(pageName)` check
///   could never match — so compare per artist-name, in both directions,
///   CJK-normalized. This regression is what silently emptied the section.
public enum ArtistMatch {
    public static func matches(_ track: Track, browseId: String, pageName: String) -> Bool {
        let channelId = browseId.hasPrefix("MPLA") ? String(browseId.dropFirst(4)) : browseId
        if track.artists.contains(where: { $0.id == channelId || $0.id == browseId }) {
            return true
        }
        guard !pageName.isEmpty else { return false }
        let page = pageName.matchNormalized
        for a in track.artists where !a.name.isEmpty {
            let name = a.name.matchNormalized
            if page.contains(name) || name.contains(page) { return true }
        }
        let line = track.artistLine.matchNormalized
        return !line.isEmpty && (page.contains(line) || line.contains(page))
    }
}

/// Shared, pure sort/filter logic for library & collection lists, so the macOS
/// and iOS apps behave identically (and it's unit-testable without any UI).

public enum TrackOrder: Sendable {
    case source        // keep as-is (e.g. "Playlist Order" / library's recently-added)
    case reversed      // reverse of source (e.g. playlist "Recently Added")
    case title
    case artist
    case album
    case plays         // global play count, high → low (tracks without counts last)
}

public enum CardOrder: Sendable {
    case source
    case reversed
    case title
    case subtitle
}

public enum LibrarySort {

    // MARK: Tracks

    public static func filter(_ tracks: [Track], query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).matchNormalized
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.matches(normalizedQuery: q)
                || $0.artistLine.matches(normalizedQuery: q)
                || ($0.album?.name.matches(normalizedQuery: q) ?? false)
        }
    }

    public static func sort(_ tracks: [Track], by order: TrackOrder) -> [Track] {
        switch order {
        case .source:
            return tracks
        case .reversed:
            return tracks.reversed()
        case .title:
            return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return tracks.sorted { tieBreak($0.artistLine, $1.artistLine, $0.title, $1.title) }
        case .album:
            // Tracks with no album sort last (a "~" sentinel would sort them
            // FIRST under locale-aware comparison, where symbols precede letters).
            return tracks.sorted { lhs, rhs in
                let a = lhs.album?.name ?? "", b = rhs.album?.name ?? ""
                if a.isEmpty != b.isEmpty { return b.isEmpty }
                return tieBreak(a, b, lhs.title, rhs.title)
            }
        case .plays:
            return tracks.sorted { lhs, rhs in
                let a = lhs.playCountValue ?? -1, b = rhs.playCountValue ?? -1
                if a != b { return a > b }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    /// Whether a list is play-count-ranked (e.g. an artist's "Top songs"), used
    /// to default those lists to the Plays sort.
    public static func hasPlayCounts(_ tracks: [Track]) -> Bool {
        tracks.contains { $0.playCountValue != nil }
    }

    /// Filter then sort in one call.
    public static func arrange(_ tracks: [Track], query: String, order: TrackOrder) -> [Track] {
        sort(filter(tracks, query: query), by: order)
    }

    // MARK: Cards

    public static func filterCards(_ cards: [CardItem], query: String) -> [CardItem] {
        let q = query.trimmingCharacters(in: .whitespaces).matchNormalized
        guard !q.isEmpty else { return cards }
        return cards.filter { $0.title.matches(normalizedQuery: q) || $0.subtitle.matches(normalizedQuery: q) }
    }

    public static func sortCards(_ cards: [CardItem], by order: CardOrder) -> [CardItem] {
        switch order {
        case .source:
            return cards
        case .reversed:
            return cards.reversed()
        case .title:
            return cards.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .subtitle:
            return cards.sorted { tieBreak($0.subtitle, $1.subtitle, $0.title, $1.title) }
        }
    }

    public static func arrangeCards(_ cards: [CardItem], query: String, order: CardOrder) -> [CardItem] {
        sortCards(filterCards(cards, query: query), by: order)
    }

    // MARK: -

    /// Compare primary keys case-insensitively, breaking ties on a secondary key.
    private static func tieBreak(_ a: String, _ b: String, _ a2: String, _ b2: String) -> Bool {
        let c = a.localizedCaseInsensitiveCompare(b)
        if c != .orderedSame { return c == .orderedAscending }
        return a2.localizedCaseInsensitiveCompare(b2) == .orderedAscending
    }
}
