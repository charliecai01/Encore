import Foundation

/// Rotates a shelf's items on a weekly cadence.
///
/// YouTube's genre pages (R&B & soul, Decades) are editorial, not personalized
/// — they return the same songs in the same order for days on end, so the same
/// track sits in the first slot every launch ("I have been seeing Billie Jean
/// for a few days now"). Neither app caches these, so re-fetching doesn't help;
/// the variety has to come from us.
///
/// Rotating rather than shuffling keeps the whole shelf reachable (nothing is
/// dropped, the order just starts further in), and keying it to the week —
/// rather than to `Date()` at render time — means the shelf stays put while
/// you scroll, and only moves on once a week.
public enum WeeklyRotation {

    private static let week: TimeInterval = 7 * 24 * 60 * 60

    /// Whole weeks since the epoch. The boundary lands on a Thursday (the
    /// epoch was one); the exact day doesn't matter, only that it's stable.
    public static func weekIndex(at date: Date = Date()) -> Int {
        Int((date.timeIntervalSince1970 / week).rounded(.down))
    }

    /// `items` rotated left by a week-stable offset. Same contents, different
    /// starting point each week.
    public static func rotate<T>(_ items: [T], at date: Date = Date()) -> [T] {
        guard items.count > 1 else { return items }
        let raw = weekIndex(at: date) % items.count
        let offset = (raw + items.count) % items.count   // negative-safe
        guard offset != 0 else { return items }
        return Array(items[offset...]) + Array(items[..<offset])
    }

    /// Rotates every shelf's items, leaving titles and ordering of the shelves
    /// themselves alone.
    public static func rotateItems(in shelves: [Shelf], at date: Date = Date()) -> [Shelf] {
        shelves.map {
            Shelf(title: $0.title, items: rotate($0.items, at: date), moreBrowseId: $0.moreBrowseId)
        }
    }
}
