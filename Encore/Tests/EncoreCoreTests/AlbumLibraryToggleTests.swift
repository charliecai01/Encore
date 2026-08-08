import XCTest
@testable import EncoreCore

/// Guards how an album page yields its "save to library" target.
///
/// The regression these exist to prevent: the first attempt hunted the page for
/// a `toggleMenuServiceItemRenderer` whose label mentioned "library". An album
/// page carries ~11 of those — one per related-album card — so it picked an
/// arbitrary OTHER album and saved that instead, putting "Bad" and "Stayin'
/// Alive" in the library when HIStory was requested. The target must come from
/// the album's OWN audio playlist.
final class AlbumLibraryToggleTests: XCTestCase {

    /// An album page: its own shelf playlistId, plus related-album menus whose
    /// like targets point at completely different albums.
    private var albumPage: JSONValue {
        JSONValue(any: [
            "contents": [
                "musicPlaylistShelfRenderer": [
                    "playlistId": "OLAK5uy_OWN_ALBUM",
                    "contents": [],
                ],
                "relatedShelf": [
                    "items": [
                        ["toggleMenuServiceItemRenderer": [
                            "defaultText": ["runs": [["text": "Save album to library"]]],
                            "toggledText": ["runs": [["text": "Remove album from library"]]],
                            "defaultServiceEndpoint": [
                                "likeEndpoint": ["status": "LIKE",
                                                 "target": ["playlistId": "OLAK5uy_SOME_OTHER_ALBUM"]],
                            ],
                        ]],
                        ["toggleMenuServiceItemRenderer": [
                            "defaultText": ["runs": [["text": "Save album to library"]]],
                            "toggledText": ["runs": [["text": "Remove album from library"]]],
                            "defaultServiceEndpoint": [
                                "likeEndpoint": ["status": "LIKE",
                                                 "target": ["playlistId": "OLAK5uy_YET_ANOTHER"]],
                            ],
                        ]],
                    ],
                ],
            ],
        ])
    }

    func testTargetIsTheAlbumsOwnPlaylistNotARelatedOne() {
        let page = P.collectionPage(from: albumPage, isAlbum: true)
        XCTAssertEqual(page.libraryTargetPlaylistId, "OLAK5uy_OWN_ALBUM")
        XCTAssertNotEqual(page.libraryTargetPlaylistId, "OLAK5uy_SOME_OTHER_ALBUM")
    }

    /// Playlists have no library toggle — nil is what hides the button.
    func testPlaylistPageHasNoLibraryTarget() {
        let page = P.collectionPage(from: albumPage, isAlbum: false)
        XCTAssertNil(page.libraryTargetPlaylistId)
    }

    /// Saved state is resolved against the library list by the UI, never parsed
    /// from the page — the page's toggles say "Save…" even for saved albums.
    func testParserDoesNotGuessSavedState() {
        XCTAssertNil(P.collectionPage(from: albumPage, isAlbum: true).savedToLibrary)
    }

    func testAlbumWithoutAPlaylistIdHasNoTarget() {
        let bare = JSONValue(any: ["contents": [:]])
        XCTAssertNil(P.collectionPage(from: bare, isAlbum: true).libraryTargetPlaylistId)
    }
}
