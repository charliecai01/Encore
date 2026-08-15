import XCTest
@testable import EncoreCore

final class DisplayTextTests: XCTestCase {

    /// The real stat line from Charlie's "Favorite Songs" page.
    func testViewCountIsDroppedAndTheRestKept() {
        XCTAssertEqual(DisplayText.withoutViewCount("8.4K views • 692 tracks • 49+ hours"),
                       "692 tracks • 49+ hours")
    }

    func testSingularViewIsAlsoDropped() {
        XCTAssertEqual(DisplayText.withoutViewCount("1 view • 3 tracks"), "3 tracks")
    }

    func testMiddleDotSeparatorIsSupported() {
        XCTAssertEqual(DisplayText.withoutViewCount("5M views · 12 tracks"), "12 tracks")
    }

    func testLinesWithoutAViewCountAreUntouched() {
        XCTAssertEqual(DisplayText.withoutViewCount("692 tracks • 49+ hours"),
                       "692 tracks • 49+ hours")
        XCTAssertEqual(DisplayText.withoutViewCount("2004"), "2004")
        XCTAssertEqual(DisplayText.withoutViewCount(""), "")
    }

    /// "Overview"/"Review" must not be mistaken for a view count.
    func testWordsEndingInViewAreNotMistaken() {
        XCTAssertEqual(DisplayText.withoutViewCount("Overview • 3 tracks"), "Overview • 3 tracks")
    }

    func testAViewCountOnItsOwnLeavesNothing() {
        XCTAssertEqual(DisplayText.withoutViewCount("8.4K views"), "")
    }
}
