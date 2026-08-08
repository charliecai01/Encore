import XCTest
@testable import EncoreCore

final class WeeklyRotationTests: XCTestCase {

    private let items = ["a", "b", "c", "d", "e"]
    /// 2026-08-07 — a Friday.
    private var friday: Date { Date(timeIntervalSince1970: 1_785_456_000) }

    // MARK: - Stability within a week (the whole point)

    func testSameWeekGivesTheSameOrder() {
        // The boundary is a Thursday, so Friday → the following Tuesday is one
        // week; Friday → the PREVIOUS Tuesday is not.
        let tuesday = friday.addingTimeInterval(4 * 24 * 3600)
        XCTAssertEqual(WeeklyRotation.weekIndex(at: friday),
                       WeeklyRotation.weekIndex(at: tuesday))
        XCTAssertEqual(WeeklyRotation.rotate(items, at: friday),
                       WeeklyRotation.rotate(items, at: tuesday))
    }

    func testHoursApartDoesNotReshuffle() {
        let later = friday.addingTimeInterval(6 * 3600)
        XCTAssertEqual(WeeklyRotation.rotate(items, at: friday),
                       WeeklyRotation.rotate(items, at: later))
    }

    // MARK: - It actually moves week to week

    func testNextWeekAdvancesByOne() {
        let next = friday.addingTimeInterval(7 * 24 * 3600)
        let a = WeeklyRotation.rotate(items, at: friday)
        let b = WeeklyRotation.rotate(items, at: next)
        XCTAssertNotEqual(a, b)
        // Rotation is by exactly one position per week.
        XCTAssertEqual(b.first, a[1])
    }

    func testFullCycleReturnsToStart() {
        let after = friday.addingTimeInterval(Double(items.count) * 7 * 24 * 3600)
        XCTAssertEqual(WeeklyRotation.rotate(items, at: friday),
                       WeeklyRotation.rotate(items, at: after))
    }

    // MARK: - Nothing is lost

    func testRotationPreservesEveryItem() {
        let out = WeeklyRotation.rotate(items, at: friday)
        XCTAssertEqual(out.sorted(), items.sorted())
        XCTAssertEqual(out.count, items.count)
    }

    // MARK: - Edges

    func testEmptyAndSingleAreUntouched() {
        XCTAssertEqual(WeeklyRotation.rotate([String](), at: friday), [])
        XCTAssertEqual(WeeklyRotation.rotate(["only"], at: friday), ["only"])
    }

    func testPreEpochDateDoesNotCrashOrGoNegative() {
        let old = Date(timeIntervalSince1970: -100_000)
        let out = WeeklyRotation.rotate(items, at: old)
        XCTAssertEqual(out.sorted(), items.sorted())
    }

    // MARK: - Shelf helper

    func testRotateItemsKeepsShelfTitlesAndOrder() {
        let shelves = [
            Shelf(title: "R&B · Songs", items: (0..<5).map { .track(Track(videoId: "\($0)", title: "\($0)")) }),
            Shelf(title: "Classics · 1970s", items: (0..<3).map { .track(Track(videoId: "c\($0)", title: "c\($0)")) }),
        ]
        let out = WeeklyRotation.rotateItems(in: shelves, at: friday)
        XCTAssertEqual(out.map(\.title), ["R&B · Songs", "Classics · 1970s"])
        XCTAssertEqual(out[0].items.count, 5)
        XCTAssertEqual(out[1].items.count, 3)
    }

    func testMoreBrowseIdSurvivesRotation() {
        let shelves = [Shelf(title: "x",
                             items: (0..<4).map { .track(Track(videoId: "\($0)", title: "\($0)")) },
                             moreBrowseId: "VLabc")]
        XCTAssertEqual(WeeklyRotation.rotateItems(in: shelves, at: friday).first?.moreBrowseId, "VLabc")
    }
}
