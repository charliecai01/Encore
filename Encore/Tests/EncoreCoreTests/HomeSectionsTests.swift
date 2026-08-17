import XCTest
@testable import EncoreCore

/// Home pins Charlie's two playlists in a specific order (Favorite Songs, R&B
/// by Sonnet) — the server returns them in a different order, so the ordering
/// has to be applied client-side. "Liked Music" used to pin third; it was
/// emptied and hidden from every playlist list on 2026-08-16.
final class HomeSectionsTests: XCTestCase {

    private func playlist(_ title: String, id: String? = nil) -> CardItem {
        CardItem(kind: .playlist, title: title, playlistId: id ?? title)
    }

    /// The order `libraryPlaylists()` actually returned for Charlie's account.
    private var serverOrder: [CardItem] {
        [playlist("R&B by Sonnet", id: "PLG26P6IqjO9k"),
         playlist("Favorite Songs", id: "PLBUNeScG9eAUjqbRwLMAk0ZsRnBD3KcWb")]
    }

    /// The R&B playlist was renamed from "R&B by Sonnet5" to "R&B by Sonnet"
    /// the day this shipped; an exact-title pin silently dropped it to the
    /// bottom of Home. Both spellings must pin to slot 2.
    func testRnbPinsUnderEitherSpelling() {
        for title in ["R&B by Sonnet", "R&B by Sonnet5"] {
            let input = [playlist("Road Trip"), playlist(title), playlist("Favorite Songs")]
            XCTAssertEqual(HomeSections.orderedPlaylists(input).map(\.title),
                           ["Favorite Songs", title, "Road Trip"],
                           "failed for \(title)")
        }
    }

    func testPinMatchingIsCaseInsensitive() {
        let input = [playlist("r&b by sonnet"), playlist("favorite songs")]
        XCTAssertEqual(HomeSections.orderedPlaylists(input).map(\.title),
                       ["favorite songs", "r&b by sonnet"])
    }

    /// Liked Music is hidden upstream in `libraryPlaylists()`, but if one ever
    /// reaches here it must not jump the queue — it is no longer pinned.
    func testLikedMusicIsNoLongerPinned() {
        let input = [playlist("Liked Music", id: "LM")] + serverOrder
        XCTAssertEqual(HomeSections.orderedPlaylists(input).map(\.title),
                       ["Favorite Songs", "R&B by Sonnet", "Liked Music"])
    }

    func testPinnedPlaylistsComeBackInTheRequestedOrder() {
        let out = HomeSections.orderedPlaylists(serverOrder)
        XCTAssertEqual(out.map(\.title), ["Favorite Songs", "R&B by Sonnet"])
    }

    func testNothingIsDropped() {
        let out = HomeSections.orderedPlaylists(serverOrder)
        XCTAssertEqual(out.count, serverOrder.count)
        XCTAssertEqual(Set(out.map(\.title)), Set(serverOrder.map(\.title)))
    }

    /// A playlist Charlie makes later must still appear — below the pinned
    /// ones, not silently hidden.
    func testUnpinnedPlaylistsFollowInServerOrder() {
        let input = serverOrder + [playlist("Road Trip"), playlist("Study")]
        let out = HomeSections.orderedPlaylists(input)
        XCTAssertEqual(out.map(\.title),
                       ["Favorite Songs", "R&B by Sonnet", "Road Trip", "Study"])
    }

    func testMissingPinnedPlaylistIsSkippedWithoutDisturbingTheRest() {
        let input = [playlist("Road Trip"), playlist("Favorite Songs")]
        let out = HomeSections.orderedPlaylists(input)
        XCTAssertEqual(out.map(\.title), ["Favorite Songs", "Road Trip"])
    }

    func testEmptyStaysEmpty() {
        XCTAssertTrue(HomeSections.orderedPlaylists([]).isEmpty)
    }

    func testOrderIsStableWhenNothingIsPinned() {
        let input = [playlist("A"), playlist("B"), playlist("C")]
        XCTAssertEqual(HomeSections.orderedPlaylists(input).map(\.title), ["A", "B", "C"])
    }
}
