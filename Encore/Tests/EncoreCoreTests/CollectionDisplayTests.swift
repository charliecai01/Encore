import XCTest
@testable import EncoreCore

/// Display logic for album/playlist pages and their rows — consolidated
/// 2026-08-19 from independent copies on macOS and iOS. The consolidation
/// itself surfaced a real bug (macOS never fed the header artist into name
/// resolution, so an album with no per-track credit stayed romanized on Mac
/// forever); these tests exist so that class of drift can't recur silently.
final class CollectionDisplayTests: XCTestCase {

    // MARK: - String.subtitleParts

    func testSubtitlePartsSplitsOnEitherBulletCharacter() {
        XCTAssertEqual("David Tao • Album • 2014".subtitleParts, ["David Tao", "Album", "2014"])
        XCTAssertEqual("David Tao · Album · 2014".subtitleParts, ["David Tao", "Album", "2014"])
    }

    func testSubtitlePartsTrimsWhitespaceAndDropsEmptyParts() {
        XCTAssertEqual("  David Tao  •  Album ".subtitleParts, ["David Tao", "Album"])
        XCTAssertEqual("David Tao • • Album".subtitleParts, ["David Tao", "Album"])
    }

    func testSubtitlePartsOfEmptyStringIsEmpty() {
        XCTAssertEqual("".subtitleParts, [])
    }

    // MARK: - CollectionPage.headerArtist

    func testHeaderArtistIsTheLeadingSubtitlePartForAlbums() {
        let page = CollectionPage(title: "Soul Power", subtitle: "David Tao • Album • 2014")
        XCTAssertEqual(page.headerArtist(isAlbum: true), "David Tao")
    }

    /// Playlists are billed to their owner, not an artist — the leading
    /// subtitle part there is a name but not one to resolve or fall back to.
    func testHeaderArtistIsNilForPlaylists() {
        let page = CollectionPage(title: "Favorite Songs", subtitle: "Charlie Cai • 665 tracks")
        XCTAssertNil(page.headerArtist(isAlbum: false))
    }

    func testHeaderArtistIsNilWhenSubtitleIsEmpty() {
        let page = CollectionPage(title: "Untitled", subtitle: "")
        XCTAssertNil(page.headerArtist(isAlbum: true))
    }

    // MARK: - artistNameCandidates

    private func track(_ title: String, artists: [Ref] = [], artistLine: String = "") -> Track {
        Track(videoId: title, title: title, artists: artists, artistLine: artistLine)
    }

    func testArtistNameCandidatesPutsHeaderArtistFirst() {
        let tracks = [track("A", artistLine: "张学友")]
        let names = artistNameCandidates(in: tracks, headerArtist: "David Tao")
        XCTAssertEqual(names.first, "David Tao")
        XCTAssertTrue(names.contains("张学友"))
    }

    func testArtistNameCandidatesDedupesHeaderAgainstTrackArtists() {
        let tracks = [track("A", artistLine: "David Tao")]
        let names = artistNameCandidates(in: tracks, headerArtist: "David Tao")
        XCTAssertEqual(names, ["David Tao"])
    }

    /// The exact regression: an album whose tracks carry no artist credit at
    /// all (common — YouTube treats it as implied by the album) must still
    /// surface the header artist as a candidate, or nothing about that album
    /// ever resolves to its native name.
    func testArtistNameCandidatesSurfacesHeaderEvenWhenNoTrackHasAnArtist() {
        let tracks = [track("A"), track("B")]
        let names = artistNameCandidates(in: tracks, headerArtist: "David Tao")
        XCTAssertEqual(names, ["David Tao"])
    }

    func testArtistNameCandidatesWithNilHeaderJustUsesTracks() {
        let tracks = [track("A", artistLine: "张学友")]
        XCTAssertEqual(artistNameCandidates(in: tracks, headerArtist: nil), ["张学友"])
    }

    func testArtistNameCandidatesIsEmptyForEmptyInput() {
        XCTAssertEqual(artistNameCandidates(in: [], headerArtist: nil), [])
    }

    // MARK: - Track.resolvedArtist / rowSubtitle

    func testResolvedArtistUsesTheTracksOwnCreditWhenPresent() {
        let t = track("A", artistLine: "郁可唯")
        XCTAssertEqual(t.resolvedArtist(fallbackArtist: "David Tao"), "郁可唯")
    }

    /// The exact bug: an album row with no per-track artist showed a
    /// dangling " · plays" with no singer at all until the fallback existed.
    func testResolvedArtistFallsBackWhenTrackHasNoCredit() {
        let t = track("A")
        XCTAssertEqual(t.resolvedArtist(fallbackArtist: "David Tao"), "陶喆",
                       "fallback artist must ALSO get native-name resolution, not pass through romanized")
    }

    func testResolvedArtistIsEmptyWhenNeitherTrackNorFallbackHasACredit() {
        let t = track("A")
        XCTAssertEqual(t.resolvedArtist(fallbackArtist: nil), "")
    }

    func testRowSubtitleJoinsArtistAndPlaysWithMiddleDot() {
        let t = Track(videoId: "A", title: "A", artistLine: "郁可唯", playsText: "70K plays")
        XCTAssertEqual(t.rowSubtitle(), "郁可唯 · 70K plays")
    }

    /// The original bug report, verbatim: a row with no track artist and no
    /// fallback used to render " · 70K plays" — a leading dangling
    /// separator. Must now render just the plays, with nothing before it.
    func testRowSubtitleHasNoDanglingSeparatorWhenArtistIsMissing() {
        let t = Track(videoId: "A", title: "A", playsText: "70K plays")
        XCTAssertEqual(t.rowSubtitle(), "70K plays")
    }

    func testRowSubtitleHasNoDanglingSeparatorWhenPlaysIsMissing() {
        let t = Track(videoId: "A", title: "A", artistLine: "郁可唯")
        XCTAssertEqual(t.rowSubtitle(), "郁可唯")
    }

    func testRowSubtitleUsesResolvedFallbackPlusPlays() {
        let t = Track(videoId: "A", title: "A", playsText: "1.5M plays")
        XCTAssertEqual(t.rowSubtitle(fallbackArtist: "David Tao"), "陶喆 · 1.5M plays")
    }

    func testRowSubtitleOfCompletelyBlankTrackIsEmpty() {
        let t = Track(videoId: "A", title: "A")
        XCTAssertEqual(t.rowSubtitle(), "")
    }
}
