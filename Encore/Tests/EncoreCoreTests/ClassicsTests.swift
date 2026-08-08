import XCTest
@testable import EncoreCore

/// The Decades category returns every decade newest-first; we surface only the
/// classic ones, in our own order. These guard the selection, not the network.
final class ClassicsTests: XCTestCase {

    private func shelf(_ title: String, items: Int = 3) -> Shelf {
        Shelf(title: title,
              items: (0..<items).map { .track(Track(videoId: "\(title)-\($0)", title: "t\($0)")) })
    }

    /// Shaped like the real response: newest decade first.
    private var decadesPage: [Shelf] {
        ["2010s", "2000s", "1990s", "1980s", "1970s", "1960s"].map { shelf($0) }
    }

    func testPicksOnlyTheClassicDecades() {
        let out = YTM.Genre.classicShelves(from: decadesPage)
        XCTAssertEqual(out.map(\.title), ["Classics · 1970s", "Classics · 1980s"])
    }

    func testUsesOurOrderNotYouTubes() {
        // YouTube lists 1980s before 1970s; we want 70s first.
        let out = YTM.Genre.classicShelves(from: decadesPage)
        XCTAssertEqual(out.first?.title, "Classics · 1970s")
    }

    func testKeepsTheItems() {
        let out = YTM.Genre.classicShelves(from: decadesPage)
        XCTAssertEqual(out.first?.items.count, 3)
    }

    func testEmptyShelvesAreDropped() {
        let page = [shelf("1970s", items: 0), shelf("1980s")]
        XCTAssertEqual(YTM.Genre.classicShelves(from: page).map(\.title), ["Classics · 1980s"])
    }

    func testMissingDecadesAreSkippedNotFaked() {
        XCTAssertEqual(YTM.Genre.classicShelves(from: [shelf("2010s")]), [])
    }

    func testEmptyPageYieldsNothing() {
        XCTAssertTrue(YTM.Genre.classicShelves(from: []).isEmpty)
    }
}
