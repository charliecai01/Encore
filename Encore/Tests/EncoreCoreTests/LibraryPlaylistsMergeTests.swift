import XCTest
@testable import EncoreCore

/// On 2026-10-15 FEmusic_liked_playlists stopped returning Charlie's own
/// "Fav Songs" while FEmusic_library_landing still listed it, so
/// `libraryPlaylists()` merges the two. These pin the merge rules.
final class LibraryPlaylistsMergeTests: XCTestCase {

    private func playlist(_ title: String, _ id: String) -> CardItem {
        CardItem(kind: .playlist, title: title, browseId: "VL" + id, playlistId: id)
    }

    private func album(_ title: String) -> CardItem {
        CardItem(kind: .album, title: title, browseId: "MPREb_" + title)
    }

    /// The real shapes the two endpoints returned that day.
    func testPlaylistMissingFromGridComesBackFromLanding() {
        let landing = [playlist("Fav Songs", "PLBUNeScG9eAUjqbRwLMAk0ZsRnBD3KcWb"),
                       playlist("R&B by Sonnet", "PLG26P6IqjO9k"),
                       album("Live At Eventim Apollo"),
                       playlist("蕾蕾的歌单", "PLcrDBImhxnK1my3whRH6fou3TJ4AMhL70"),
                       playlist("Episodes for Later", "SE")]
        let grid = [playlist("R&B by Sonnet", "PLG26P6IqjO9k"),
                    playlist("蕾蕾的歌单", "PLcrDBImhxnK1my3whRH6fou3TJ4AMhL70"),
                    playlist("Episodes for Later", "SE")]
        XCTAssertEqual(YTM.mergedLibraryPlaylists(landing: landing, grid: grid).map(\.title),
                       ["Fav Songs", "R&B by Sonnet", "蕾蕾的歌单"])
    }

    /// The landing page has no continuation; grid-only playlists must survive.
    func testGridOnlyPlaylistsAreKept() {
        let landing = [playlist("A", "PLa")]
        let grid = [playlist("A", "PLa"), playlist("B", "PLb")]
        XCTAssertEqual(YTM.mergedLibraryPlaylists(landing: landing, grid: grid).map(\.title), ["A", "B"])
    }

    func testFailedLandingFetchFallsBackToGrid() {
        let grid = [playlist("A", "PLa"), playlist("Liked Music", "LM")]
        XCTAssertEqual(YTM.mergedLibraryPlaylists(landing: [], grid: grid).map(\.title), ["A"])
    }
}
