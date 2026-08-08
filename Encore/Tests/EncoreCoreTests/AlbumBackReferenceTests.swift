import XCTest
@testable import EncoreCore

/// Tracks played off an album page must remember WHICH album they came from.
///
/// Album rows don't repeat the album name, so their `album` ref comes from the
/// page's fallback. That fallback used to carry a nil id, so "tap the song
/// title in the player bar to open its album" silently did nothing for any
/// track played from an album.
final class AlbumBackReferenceTests: XCTestCase {

    private var albumPage: JSONValue {
        JSONValue(any: [
            "header": [
                "musicDetailHeaderRenderer": [
                    "title": ["runs": [["text": "HIStory: PAST, PRESENT AND FUTURE, BOOK I"]]],
                ],
            ],
            "contents": [
                "musicPlaylistShelfRenderer": [
                    "playlistId": "OLAK5uy_history",
                    "contents": [
                        ["musicResponsiveListItemRenderer": [
                            "playlistItemData": ["videoId": "meBHKKdMnGI"],
                            "flexColumns": [
                                ["musicResponsiveListItemFlexColumnRenderer":
                                    ["text": ["runs": [["text": "Billie Jean"]]]]],
                            ],
                        ]],
                    ],
                ],
            ],
        ])
    }

    func testAlbumTracksCarryTheAlbumBrowseId() throws {
        let page = P.collectionPage(from: albumPage, isAlbum: true,
                                    albumBrowseId: "MPREb_L7mH5RJKKdI")
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.album?.id, "MPREb_L7mH5RJKKdI",
                       "no album id means tapping the title in the player bar does nothing")
    }

    func testAlbumNameStillComesFromTheHeader() throws {
        let page = P.collectionPage(from: albumPage, isAlbum: true,
                                    albumBrowseId: "MPREb_L7mH5RJKKdI")
        XCTAssertEqual(try XCTUnwrap(page.tracks.first).album?.name,
                       "HIStory: PAST, PRESENT AND FUTURE, BOOK I")
    }

    /// Playlists must not stamp their own id onto tracks as an "album".
    func testPlaylistTracksGetNoFallbackAlbum() throws {
        let page = P.collectionPage(from: albumPage, isAlbum: false)
        XCTAssertNil(try XCTUnwrap(page.tracks.first).album)
    }

    /// Callers that don't know the browseId still parse fine, just without the
    /// back-reference — no crash, no bogus id.
    func testMissingBrowseIdLeavesTheIdNil() throws {
        let page = P.collectionPage(from: albumPage, isAlbum: true)
        XCTAssertNil(try XCTUnwrap(page.tracks.first).album?.id)
    }
}
