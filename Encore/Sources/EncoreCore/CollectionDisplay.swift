import Foundation

/// Best-effort release year for an album, resolved off its browseId when a
/// track doesn't already carry one — the common case for anything queued
/// from a mixed playlist/radio/library rather than the album page itself,
/// which is the only place YouTube states a year on the row data this app
/// parses. In-memory only per launch (Charlie, 2026-08-22: mini player
/// "artist • album • year" line) — cheap enough to refetch, and correctness
/// matters more than persistence since `Track.year`'s own fallback already
/// covers the far more common "play from the album" path for free.
public enum AlbumYear {
    private static let cache = LookupCache()

    /// The year if it's already known, without doing any network work.
    public static func cached(albumId: String) -> String? {
        if case .hit(let year) = cache.state(for: albumId) { return year }
        return nil
    }

    /// Fetches the album page and extracts its year, caching the result —
    /// including a cached miss (empty string), so an album with no stated
    /// year isn't refetched every time one of its tracks plays.
    public static func resolve(albumId: String) async -> String? {
        switch cache.state(for: albumId) {
        case .hit(let year): return year
        case .miss: return nil
        case .notCached: break
        }
        let year = (try? await YTM.shared.album(browseId: albumId))?.headerYear(isAlbum: true)
        cache.store(year, for: albumId)
        return year
    }
}

/// Display logic for album/playlist pages and their rows, shared so macOS and
/// iOS can't drift. Both apps used to carry their own copy of every function
/// here; one gap — macOS's copy of `artistNameCandidates` never existed, so
/// an album with no per-track artist credit (implied by the album, which
/// YouTube omits often) stayed romanized forever on Mac while the same album
/// resolved to its native name on iOS. Found consolidating this on
/// 2026-08-19 (Charlie: "is anything worth refactoring").
public extension String {
    /// Splits a YouTube-style "•"/"·"-joined subtitle line into trimmed,
    /// non-empty parts — "David Tao • Album • 2014" → ["David Tao", "Album",
    /// "2014"]. Card subtitles arrive pre-joined with no separate artist
    /// field, so each part is a candidate name and the caller decides.
    var subtitleParts: [String] {
        components(separatedBy: CharacterSet(charactersIn: "•·"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public extension CollectionPage {
    /// The artist an ALBUM page is billed to. Subtitles arrive pre-joined and
    /// artist-first ("David Tao • Album • 2014"), so the leading part is the
    /// name. Pass `isAlbum: false` for playlists and podcasts — those are
    /// billed to their owner/show, not an artist, and the leading subtitle
    /// part isn't a name at all.
    func headerArtist(isAlbum: Bool) -> String? {
        guard isAlbum else { return nil }
        return subtitle.subtitleParts.first
    }

    /// The year an ALBUM page was released — the last "•"-joined subtitle
    /// part, when it's a plain number ("张学友 • Album • 2004" → "2004").
    /// nil for playlists/podcasts and for the rare album whose subtitle
    /// omits a year.
    func headerYear(isAlbum: Bool) -> String? {
        guard isAlbum, let last = subtitle.subtitleParts.last, !last.isEmpty,
              last.allSatisfy(\.isNumber) else { return nil }
        return last
    }
}

/// Every artist name worth resolving to its native display form for a page:
/// the header artist first (so what's on screen resolves first), then each
/// track's own credits in display order. Feed this to `NativeNames.warmUp`.
public func artistNameCandidates(in tracks: [Track], headerArtist: String?) -> [String] {
    var names: [String] = []
    var seen = Set<String>()
    if let headerArtist, !headerArtist.isEmpty, seen.insert(headerArtist).inserted {
        names.append(headerArtist)
    }
    for track in tracks {
        for name in track.artists.map(\.name) + [track.artistLine]
        where !name.isEmpty && seen.insert(name).inserted {
            names.append(name)
        }
    }
    return names
}

public extension Track {
    /// The credited artist, falling back to `fallbackArtist` when the track
    /// carries none itself (YouTube omits the per-track artist on many album
    /// pages since it's implied by the album), rewritten to its resolved
    /// native-script name (张学友, not "Jacky Cheung") once resolution lands.
    /// Charlie, 2026-08-18: "where is the singer name" — some album pages'
    /// rows had no artist at all without this fallback.
    func resolvedArtist(fallbackArtist: String? = nil) -> String {
        let credited = artistLine.isEmpty ? (fallbackArtist ?? "") : artistLine
        return NativeNames.rewriting(credited, artists: artists.map(\.name) + [credited])
    }

    /// The line shown under a track's title in a list row that joins artist
    /// and play count into one string (iOS): `resolvedArtist` plus a
    /// trailing "N plays" when present. Joined from non-empty parts only, so
    /// a missing artist or missing play count never leaves a dangling " · ".
    /// macOS shows plays in a separate trailing column instead, so it calls
    /// `resolvedArtist` directly rather than this.
    func rowSubtitle(fallbackArtist: String? = nil) -> String {
        [resolvedArtist(fallbackArtist: fallbackArtist), playsText ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A copy with `artistLine` (and, when given, an `artists` ref) filled
    /// from the album header when this track carries none of its own. Bake
    /// this in BEFORE queueing (not just at row display) so every consumer
    /// downstream of the queue — MiniPlayer, Now Playing, the lock-screen/
    /// Control-Center metadata — shows the same artist the row itself
    /// showed, instead of reading the still-blank `artistLine` straight off
    /// the un-fallback-applied Track (Charlie, 2026-08-22: mini player
    /// showed a title with no artist line under it for album tracks YouTube
    /// omits the per-track credit on).
    ///
    /// `fallbackRef` additionally seeds `artists` — without an id there,
    /// "tap the artist name to open their page" has a name to show but
    /// nowhere to navigate to, since that's the only place `openArtist()`
    /// looks (Charlie, 2026-08-22: "clicking on artist name do not go to
    /// artist page").
    func withFallbackArtist(_ fallbackArtist: String?, ref fallbackRef: Ref? = nil) -> Track {
        guard artistLine.isEmpty else { return self }
        var copy = self
        if let fallbackArtist, !fallbackArtist.isEmpty { copy.artistLine = fallbackArtist }
        if copy.artists.isEmpty, let fallbackRef { copy.artists = [fallbackRef] }
        return copy
    }

    /// A copy with `year` filled in when this track doesn't carry one of its
    /// own — same fallback pattern as `withFallbackArtist`, for the macOS
    /// mini player's "artist • album • year" line (Charlie, 2026-08-22).
    func withYear(_ fallbackYear: String?) -> Track {
        guard year == nil, let fallbackYear, !fallbackYear.isEmpty else { return self }
        var copy = self
        copy.year = fallbackYear
        return copy
    }
}
