import XCTest
@testable import EncoreCore

final class MonthlyRotationTests: XCTestCase {

    private let items = ["a", "b", "c", "d", "e"]
    /// 2026-08-13.
    private var midAugust: Date { Date(timeIntervalSince1970: 1_786_752_000) }

    // MARK: - Stability within a month (the whole point)

    func testSameMonthGivesTheSameOrder() {
        let laterInMonth = midAugust.addingTimeInterval(10 * 24 * 3600)
        XCTAssertEqual(MonthlyRotation.monthIndex(at: midAugust),
                       MonthlyRotation.monthIndex(at: laterInMonth))
        XCTAssertEqual(MonthlyRotation.rotate(items, at: midAugust),
                       MonthlyRotation.rotate(items, at: laterInMonth))
    }

    func testHoursApartDoesNotReshuffle() {
        let later = midAugust.addingTimeInterval(6 * 3600)
        XCTAssertEqual(MonthlyRotation.rotate(items, at: midAugust),
                       MonthlyRotation.rotate(items, at: later))
    }

    // MARK: - It actually moves month to month

    func testNextMonthAdvancesByAStride() {
        let calendar = Calendar(identifier: .gregorian)
        let next = calendar.date(byAdding: .month, value: 1, to: midAugust)!
        let a = MonthlyRotation.rotate(items, at: midAugust)
        let b = MonthlyRotation.rotate(items, at: next)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b.first, a[MonthlyRotation.stride(forCount: items.count)])
    }

    /// The regression WeeklyRotation guards against, one cadence up: a
    /// 300-song pool showing 100 of them must not hand back essentially the
    /// same 100 next month.
    func testVisibleWindowActuallyTurnsOverMonthToMonth() {
        let calendar = Calendar(identifier: .gregorian)
        let pool = (0..<300).map { $0 }
        let next = calendar.date(byAdding: .month, value: 1, to: midAugust)!
        let thisMonth = Set(MonthlyRotation.rotate(pool, at: midAugust).prefix(100))
        let nextMonth = Set(MonthlyRotation.rotate(pool, at: next).prefix(100))
        let carriedOver = thisMonth.intersection(nextMonth).count
        XCTAssertLessThanOrEqual(carriedOver, 70, "window barely moved: \(carriedOver)/100 repeated")
    }

    func testStrideIsAtLeastOneForTinyPools() {
        XCTAssertEqual(MonthlyRotation.stride(forCount: 2), 1)
        XCTAssertEqual(MonthlyRotation.stride(forCount: 0), 1)
    }

    // MARK: - Nothing is lost

    func testRotationPreservesEveryItem() {
        let out = MonthlyRotation.rotate(items, at: midAugust)
        XCTAssertEqual(out.sorted(), items.sorted())
        XCTAssertEqual(out.count, items.count)
    }

    // MARK: - Edges

    func testEmptyAndSingleAreUntouched() {
        XCTAssertEqual(MonthlyRotation.rotate([String](), at: midAugust), [])
        XCTAssertEqual(MonthlyRotation.rotate(["only"], at: midAugust), ["only"])
    }

    func testYearBoundaryDoesNotCrashOrGoNegative() {
        let calendar = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 12; comps.day = 20
        let december = calendar.date(from: comps)!
        let out = MonthlyRotation.rotate(items, at: december)
        XCTAssertEqual(out.sorted(), items.sorted())
    }
}
