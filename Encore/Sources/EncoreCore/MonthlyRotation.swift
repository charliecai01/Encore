import Foundation

/// Rotates a pool of items on a monthly cadence — the same algorithm as
/// `WeeklyRotation`, keyed to the calendar month instead of the week.
///
/// Used to pick which ~100 songs of a larger curated pool make up a
/// generated playlist (e.g. "R&B by Sonnet5") this month: same pool, a
/// different starting window each month, so the playlist stays fresh without
/// ever being reshuffled into a totally different set.
public enum MonthlyRotation {

    /// Calendar months since year 0 (year*12 + month). Using the calendar
    /// directly — rather than a fixed seconds-per-month interval like
    /// `WeeklyRotation`'s epoch math — keeps month boundaries aligned to
    /// actual months regardless of their varying length.
    public static func monthIndex(at date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 12 + (c.month ?? 0)
    }

    /// How far the window moves each month: a third of the pool (same
    /// reasoning as `WeeklyRotation.stride` — stepping by one is invisible).
    public static func stride(forCount count: Int) -> Int {
        max(1, count / 3)
    }

    /// `items` rotated left by a month-stable offset. Same contents, different
    /// starting point each calendar month.
    public static func rotate<T>(_ items: [T], at date: Date = Date()) -> [T] {
        guard items.count > 1 else { return items }
        let raw = (monthIndex(at: date) * stride(forCount: items.count)) % items.count
        let offset = (raw + items.count) % items.count   // negative-safe
        guard offset != 0 else { return items }
        return Array(items[offset...]) + Array(items[..<offset])
    }
}
