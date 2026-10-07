import Foundation

/// Multi-select rules for a song list, Finder-style: a plain or ⌘-click
/// toggles one row and becomes the anchor; a ⇧-click adds every row between
/// the anchor and the clicked row. The anchor stays put across ⇧-clicks so
/// repeated ⇧-clicks all extend from the same place.
public enum TrackSelection {

    public enum Click: Sendable {
        /// Plain or ⌘-click: flip this one row.
        case toggle
        /// ⇧-click: add the anchor…clicked run.
        case range
    }

    /// Applies `click` on `ids[index]`. `anchor` is the videoId of the last
    /// toggled row; with no anchor (or one no longer in the list, e.g. after a
    /// filter) a range click falls back to selecting just the clicked row.
    public static func apply(_ click: Click,
                             at index: Int,
                             in ids: [String],
                             selection: Set<String>,
                             anchor: String?) -> (selection: Set<String>, anchor: String?) {
        guard ids.indices.contains(index) else { return (selection, anchor) }
        let clicked = ids[index]
        var result = selection

        if click == .range, let anchor, let from = ids.firstIndex(of: anchor) {
            let run = from <= index ? ids[from...index] : ids[index...from]
            result.formUnion(run)
            return (result, anchor)
        }
        if click == .range {
            result.insert(clicked)
        } else if result.contains(clicked) {
            result.remove(clicked)
        } else {
            result.insert(clicked)
        }
        return (result, clicked)
    }
}
