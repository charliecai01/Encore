import XCTest
@testable import EncoreCore

final class ArtistMatchTests: XCTestCase {
    private let davidTaoId = "UCUfR8ZO3dAsLC5yQx1E4E9Q"

    private func track(artists: [Ref], line: String = "") -> Track {
        Track(videoId: "v", title: "t", artists: artists, artistLine: line)
    }

    func testMatchesByArtistId() {
        let t = track(artists: [Ref(name: "陶喆", id: davidTaoId)])
        XCTAssertTrue(ArtistMatch.matches(t, browseId: davidTaoId, pageName: "陶喆 - David Tao"))
    }

    func testMatchesByMPLAAliasId() {
        let t = track(artists: [Ref(name: "陶喆", id: davidTaoId)])
        XCTAssertTrue(ArtistMatch.matches(t, browseId: "MPLA" + davidTaoId, pageName: ""))
    }

    /// The regression: combined page titles ("陶喆 - David Tao") never matched
    /// `artistLine.contains(pageName)` — id-less refs lost the section.
    func testCombinedPageNameMatchesIdlessRef() {
        let t = track(artists: [Ref(name: "陶喆", id: nil)])
        XCTAssertTrue(ArtistMatch.matches(t, browseId: davidTaoId, pageName: "陶喆 - David Tao"))
    }

    func testCombinedPageNameMatchesEnglishHalf() {
        let t = track(artists: [Ref(name: "David Tao", id: nil)])
        XCTAssertTrue(ArtistMatch.matches(t, browseId: davidTaoId, pageName: "陶喆 - David Tao"))
    }

    func testArtistLineFallbackWithoutRefs() {
        let t = track(artists: [], line: "陶喆")
        XCTAssertTrue(ArtistMatch.matches(t, browseId: davidTaoId, pageName: "陶喆 - David Tao"))
    }

    func testTraditionalSimplifiedInterop() {
        // Page uses traditional, ref uses simplified — CJK normalization bridges.
        let t = track(artists: [Ref(name: "周杰伦", id: nil)])
        XCTAssertTrue(ArtistMatch.matches(t, browseId: "UCx", pageName: "周杰倫 - Jay Chou"))
    }

    func testNoMatchForUnrelatedArtist() {
        let t = track(artists: [Ref(name: "林俊傑", id: "UCother")], line: "林俊傑")
        XCTAssertFalse(ArtistMatch.matches(t, browseId: davidTaoId, pageName: "陶喆 - David Tao"))
    }

    func testEmptyPageNameOnlyMatchesById() {
        let t = track(artists: [Ref(name: "陶喆", id: nil)])
        XCTAssertFalse(ArtistMatch.matches(t, browseId: davidTaoId, pageName: ""))
    }
}
