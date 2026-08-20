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
    case mostPlayed    // YOUR play count (PlayCounts), high → low
    case leastPlayed   // YOUR play count, low → high (never-played first)
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
            // Sorts on the DISPLAYED name (so an artist credited both
            // "David Tao" and "陶喆" stays in one place) and groups English
            // names first alphabetically, then Chinese names by pinyin.
            //
            // The key is computed ONCE per track up front, not inside the
            // comparator: displayArtist does a dictionary lookup + string
            // replace per credited artist, and pinyin runs a full ICU
            // transform. A naive `sorted { }` calls both sides' key on every
            // comparison — O(n log n) transforms instead of O(n) — which on
            // a 600+ track playlist sorted by Artist (iOS's default) took
            // long enough to freeze the view, especially since resolving
            // native names re-triggers this same sort several times as
            // chunks land (Charlie, 2026-08-16, "iOS app is super slow").
            let keyed = tracks.map { ($0, CJK.nameSortKey(NativeNames.displayArtist(for: $0))) }
            return keyed.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }.map(\.0)
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
        case .mostPlayed, .leastPlayed:
            // YOUR counts, not YouTube's. Snapshot the map once — PlayCounts
            // .all() decodes UserDefaults JSON, so per-comparison lookups
            // would decode it O(n log n) times.
            let counts = PlayCounts.all()
            let descending = (order == .mostPlayed)
            return tracks.sorted { lhs, rhs in
                let a = counts[lhs.videoId]?.count ?? 0
                let b = counts[rhs.videoId]?.count ?? 0
                if a != b { return descending ? a > b : a < b }
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

    // MARK: - Artist aggregation

    /// Library ▸ Artists: `corpus` (YTM's own artist list) annotated with
    /// song counts, PLUS artists collected from `tracks` that the corpus
    /// doesn't already cover — a channel-backed artist by id, everyone else
    /// grouped by name. Was independently reimplemented on macOS and iOS
    /// (identical logic, different formatting); moved here 2026-08-19 so a
    /// fix in one can't silently miss the other, the way the R&B-rename pin
    /// once did for `HomeSections`.
    public static func artistCards(corpus: [CardItem], tracks: [Track]) -> [CardItem] {
        struct Tally {
            var name: String
            var count = 0
            var thumb: URL?
        }
        var byId: [String: Tally] = [:]
        var byName: [String: Tally] = [:]

        for track in tracks {
            if track.artists.isEmpty {
                let name = track.artistLine
                    .components(separatedBy: CharacterSet(charactersIn: ",&"))
                    .first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !name.isEmpty else { continue }
                var tally = byName[name.matchNormalized] ?? Tally(name: name)
                tally.count += 1
                if tally.thumb == nil { tally.thumb = track.thumbnailURL }
                byName[name.matchNormalized] = tally
                continue
            }
            for ref in track.artists {
                // Only real channels make a navigable card; library-private
                // artist refs group by name instead.
                if let id = ref.id, id.hasPrefix("UC") {
                    var tally = byId[id] ?? Tally(name: ref.name)
                    tally.count += 1
                    if tally.thumb == nil { tally.thumb = track.thumbnailURL }
                    byId[id] = tally
                } else if !ref.name.isEmpty {
                    var tally = byName[ref.name.matchNormalized] ?? Tally(name: ref.name)
                    tally.count += 1
                    if tally.thumb == nil { tally.thumb = track.thumbnailURL }
                    byName[ref.name.matchNormalized] = tally
                }
            }
        }

        func countLabel(_ n: Int) -> String {
            "\(n) song\(n == 1 ? "" : "s")"
        }

        var out: [CardItem] = []
        var seenIds = Set<String>()
        var seenNames = Set<String>()
        for card in corpus {
            let channelId = card.browseId.map { $0.hasPrefix("MPLA") ? String($0.dropFirst(4)) : $0 }
            var item = card
            if let channelId, let tally = byId[channelId] {
                item.subtitle = countLabel(tally.count)
            }
            out.append(item)
            if let channelId { seenIds.insert(channelId) }
            seenNames.insert(card.title.matchNormalized)
        }
        // "Jacky Cheung" from an upload duplicates "張學友 - Jacky Cheung";
        // suppress aggregated cards whose name is contained in (or contains)
        // an artist we already show.
        func isDuplicate(_ name: String) -> Bool {
            let n = name.matchNormalized
            guard n.count >= 3 else { return seenNames.contains(n) }
            return seenNames.contains { $0.contains(n) || n.contains($0) }
        }

        for (id, tally) in byId.sorted(by: { $0.value.count > $1.value.count })
        where !seenIds.contains(id) && !isDuplicate(tally.name) {
            seenNames.insert(tally.name.matchNormalized)
            out.append(CardItem(kind: .artist, title: tally.name, subtitle: countLabel(tally.count),
                                thumbnailURL: tally.thumb, browseId: id))
        }
        for (key, tally) in byName where !isDuplicate(tally.name) {
            seenNames.insert(key)
            out.append(CardItem(kind: .artist, title: tally.name, subtitle: countLabel(tally.count),
                                thumbnailURL: tally.thumb))
        }

        // Most-collected artists first.
        func count(_ item: CardItem) -> Int {
            Int(item.subtitle.components(separatedBy: " ").first ?? "") ?? 0
        }
        return out.sorted {
            let c0 = count($0), c1 = count($1)
            if c0 != c1 { return c0 > c1 }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: -

    /// Compare primary keys case-insensitively, breaking ties on a secondary key.
    private static func tieBreak(_ a: String, _ b: String, _ a2: String, _ b2: String) -> Bool {
        let c = a.localizedCaseInsensitiveCompare(b)
        if c != .orderedSame { return c == .orderedAscending }
        return a2.localizedCaseInsensitiveCompare(b2) == .orderedAscending
    }
}
