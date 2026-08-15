import Foundation

/// Ordering for the Home screen's two sections.
///
/// Home is a deliberately minimal launcher (Charlie's spec, 2026-08-14): his
/// playlists, then his saved albums, and nothing else. Both apps render the
/// same two lists, so the ordering rule lives here rather than being
/// copy-pasted into two view files — the same reason `LibrarySort` exists.
public enum HomeSections {

    /// The playlists Charlie wants pinned to the top of Home, in this order.
    /// Matching is by title because the ids differ per account (and "Liked
    /// Music" is the synthetic `LM` auto-playlist).
    ///
    /// These are PREFIXES, matched case-insensitively, so a playlist that
    /// gets renamed around its stem still pins — "R&B by Sonnet5" was
    /// renamed to "R&B by Sonnet" the same day this shipped, which an
    /// exact-equality match silently dropped to the bottom of the list.
    public static let pinnedPlaylistTitles = ["Favorite Songs", "R&B by Sonnet", "Liked Music"]

    /// `playlists` with the pinned titles first in `pinnedPlaylistTitles`
    /// order, then everything else in the order the server returned it.
    /// Nothing is dropped — a playlist that isn't pinned still shows, just
    /// below the pinned ones, so the list stays correct if Charlie adds or
    /// renames playlists later.
    public static func orderedPlaylists(_ playlists: [CardItem]) -> [CardItem] {
        func rank(_ item: CardItem) -> Int {
            let title = item.title.lowercased()
            return pinnedPlaylistTitles.firstIndex { title.hasPrefix($0.lowercased()) }
                ?? pinnedPlaylistTitles.count
        }
        // Sort on (rank, original index) so the sort is stable: equal-rank
        // items keep the server's relative order.
        return playlists.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}
