import XCTest
@testable import EncoreCore

/// `LibrarySort.artistCards` — moved 2026-08-19 from two byte-identical
/// copies (macOS, iOS) into shared code. Untested on either platform before
/// this; these tests exist so a future fix to the aggregation only has to
/// happen once and is guarded going forward.
final class ArtistAggregationTests: XCTestCase {

    private func track(_ videoId: String, artists: [Ref] = [], artistLine: String = "") -> Track {
        Track(videoId: videoId, title: videoId, artists: artists, artistLine: artistLine)
    }

    /// A corpus entry (YouTube's own "In your library" artist list) gets its
    /// song count filled in from the tracks that credit its channel id.
    func testCorpusEntryGetsASongCountFromMatchingTracks() {
        let corpus = [CardItem(kind: .artist, title: "陶喆", browseId: "UC123")]
        let tracks = [track("a", artists: [Ref(name: "陶喆", id: "UC123")]),
                      track("b", artists: [Ref(name: "陶喆", id: "UC123")])]
        let out = LibrarySort.artistCards(corpus: corpus, tracks: tracks)
        XCTAssertEqual(out.first(where: { $0.browseId == "UC123" })?.subtitle, "2 songs")
    }

    func testSingularSongCountHasNoTrailingS() {
        let corpus = [CardItem(kind: .artist, title: "陶喆", browseId: "UC123")]
        let tracks = [track("a", artists: [Ref(name: "陶喆", id: "UC123")])]
        let out = LibrarySort.artistCards(corpus: corpus, tracks: tracks)
        XCTAssertEqual(out.first?.subtitle, "1 song")
    }

    /// An artist with a real channel id but absent from the corpus (YouTube's
    /// list can be incomplete) still gets a navigable card.
    func testChannelBackedArtistNotInCorpusStillGetsACard() {
        let tracks = [track("a", artists: [Ref(name: "New Artist", id: "UC999")])]
        let out = LibrarySort.artistCards(corpus: [], tracks: tracks)
        XCTAssertTrue(out.contains { $0.browseId == "UC999" && $0.title == "New Artist" })
    }

    /// Refs with no real channel id (playlist-private / featured-artist
    /// credits) group by normalized NAME instead of id.
    func testNonChannelArtistsGroupByName() {
        let tracks = [track("a", artists: [Ref(name: "庄心妍")]),
                      track("b", artists: [Ref(name: "庄心妍")])]
        let out = LibrarySort.artistCards(corpus: [], tracks: tracks)
        XCTAssertEqual(out.filter { $0.title == "庄心妍" }.count, 1)
        XCTAssertEqual(out.first { $0.title == "庄心妍" }?.subtitle, "2 songs")
    }

    /// A track with no `artists` refs at all falls back to the first
    /// comma/ampersand-delimited name in `artistLine`.
    func testTrackWithNoArtistRefsFallsBackToArtistLine() {
        let tracks = [track("a", artistLine: "郁可唯, 某某某")]
        let out = LibrarySort.artistCards(corpus: [], tracks: tracks)
        XCTAssertTrue(out.contains { $0.title == "郁可唯" })
        XCTAssertFalse(out.contains { $0.title == "某某某" },
                       "only the first name in an unstructured artistLine should be attributed")
    }

    /// "Jacky Cheung" from an upload and "張學友 - Jacky Cheung" (channel
    /// credit) must not produce two cards for the same person.
    func testNearDuplicateNamesAreSuppressed() {
        let corpus = [CardItem(kind: .artist, title: "張學友 - Jacky Cheung", browseId: "UC1")]
        let tracks = [track("a", artists: [Ref(name: "張學友 - Jacky Cheung", id: "UC1")]),
                      track("b", artists: [Ref(name: "Jacky Cheung")])]
        let out = LibrarySort.artistCards(corpus: corpus, tracks: tracks)
        XCTAssertEqual(out.count, 1)
    }

    /// Very short names (below the 3-char containment threshold) require an
    /// EXACT match to suppress — "A" must not swallow "A-Lin".
    func testShortNamesRequireExactMatchToSuppress() {
        let corpus = [CardItem(kind: .artist, title: "A-Lin", browseId: "UC1")]
        let tracks = [track("a", artists: [Ref(name: "A-Lin", id: "UC1")]),
                      track("b", artists: [Ref(name: "A")])]
        let out = LibrarySort.artistCards(corpus: corpus, tracks: tracks)
        XCTAssertTrue(out.contains { $0.title == "A" },
                      "a 1-char name shouldn't be silently absorbed into an unrelated longer one")
    }

    /// Most-collected artist first; ties break alphabetically.
    func testSortedByCountDescendingThenNameAscending() {
        let tracks = [track("a", artists: [Ref(name: "Zeta", id: "UC1")]),
                      track("b", artists: [Ref(name: "Zeta", id: "UC1")]),
                      track("c", artists: [Ref(name: "Alpha", id: "UC2")]),
                      track("d", artists: [Ref(name: "Alpha", id: "UC2")]),
                      track("e", artists: [Ref(name: "Beta", id: "UC3")])]
        let out = LibrarySort.artistCards(corpus: [], tracks: tracks)
        XCTAssertEqual(out.map(\.title), ["Alpha", "Zeta", "Beta"])
    }

    func testEmptyTracksProducesEmptyCorpusAnnotationOnly() {
        let corpus = [CardItem(kind: .artist, title: "陶喆", browseId: "UC1")]
        let out = LibrarySort.artistCards(corpus: corpus, tracks: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.subtitle, "")
    }
}
