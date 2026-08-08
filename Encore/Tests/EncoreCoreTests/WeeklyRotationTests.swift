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

    func testNextWeekAdvancesByAStride() {
        let next = friday.addingTimeInterval(7 * 24 * 3600)
        let a = WeeklyRotation.rotate(items, at: friday)
        let b = WeeklyRotation.rotate(items, at: next)
        XCTAssertNotEqual(a, b)
        // Moves by stride, not by one.
        XCTAssertEqual(b.first, a[WeeklyRotation.stride(forCount: items.count)])
    }

    /// The regression that motivated the stride: a 50-song shelf showing 30 of
    /// them must not hand back essentially the same 30 next week.
    func testVisibleWindowActuallyTurnsOverWeekToWeek() {
        let fifty = (0..<50).map { $0 }
        let next = friday.addingTimeInterval(7 * 24 * 3600)
        let thisWeek = Set(WeeklyRotation.rotate(fifty, at: friday).prefix(30))
        let nextWeek = Set(WeeklyRotation.rotate(fifty, at: next).prefix(30))
        let carriedOver = thisWeek.intersection(nextWeek).count
        // Stepping by one would leave 29 of 30 in place.
        XCTAssertLessThanOrEqual(carriedOver, 20, "window barely moved: \(carriedOver)/30 repeated")
    }

    func testWholeShelfIsReachableWithinAFewWeeks() {
        let fifty = (0..<50).map { $0 }
        var seen = Set<Int>()
        for week in 0..<3 {
            let d = friday.addingTimeInterval(Double(week) * 7 * 24 * 3600)
            seen.formUnion(WeeklyRotation.rotate(fifty, at: d).prefix(30))
        }
        XCTAssertEqual(seen.count, 50, "some songs never surface")
    }

    func testStrideIsAtLeastOneForTinyShelves() {
        XCTAssertEqual(WeeklyRotation.stride(forCount: 2), 1)
        XCTAssertEqual(WeeklyRotation.stride(forCount: 0), 1)
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
