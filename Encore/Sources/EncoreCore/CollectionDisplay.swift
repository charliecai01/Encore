import Foundation

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
}
