import XCTest
@testable import EncoreCore

/// Guards the "Save album to library" parse. The toggle is a `likeEndpoint`
/// (not a feedback token, which is the obvious guess) whose target is the
/// album's `OLAK5uy_…` audio playlist. Crucially the toggle's DEFAULT action is
/// the one currently offered, so "Save…" being the default means the album is
/// NOT yet saved — getting that backwards would show every album as saved.
final class AlbumLibraryToggleTests: XCTestCase {

    /// Shaped like the real payload.
    private func page(defaultStatus: String, toggledStatus: String) -> JSONValue {
        JSONValue(any: [
            "contents": [
                "toggleMenuServiceItemRenderer": [
                    "defaultText": ["runs": [["text": defaultStatus == "LIKE"
                                              ? "Save album to library"
                                              : "Remove album from library"]]],
                    "toggledText": ["runs": [["text": defaultStatus == "LIKE"
                                              ? "Remove album from library"
                                              : "Save album to library"]]],
                    "defaultServiceEndpoint": [
                        "likeEndpoint": ["status": defaultStatus,
                                         "target": ["playlistId": "OLAK5uy_test"]],
                    ],
                    "toggledServiceEndpoint": [
                        "likeEndpoint": ["status": toggledStatus,
                                         "target": ["playlistId": "OLAK5uy_test"]],
                    ],
                ],
            ],
        ])
    }

    func testUnsavedAlbumReportsNotSaved() {
        let t = P.libraryToggle(in: page(defaultStatus: "LIKE", toggledStatus: "INDIFFERENT"))
        XCTAssertEqual(t?.saved, false)
        XCTAssertEqual(t?.playlistId, "OLAK5uy_test")
    }

    func testSavedAlbumReportsSaved() {
        let t = P.libraryToggle(in: page(defaultStatus: "INDIFFERENT", toggledStatus: "LIKE"))
        XCTAssertEqual(t?.saved, true)
    }

    func testPageWithoutTheToggleYieldsNil() {
        let other = JSONValue(any: [
            "contents": [
                "toggleMenuServiceItemRenderer": [
                    "defaultText": ["runs": [["text": "Pin to Listen again"]]],
                    "toggledText": ["runs": [["text": "Unpin from Listen again"]]],
                    "defaultServiceEndpoint": ["feedbackEndpoint": ["feedbackToken": "abc"]],
                ],
            ],
        ])
        XCTAssertNil(P.libraryToggle(in: other))
    }

    func testCollectionPageCarriesTheToggle() {
        let parsed = P.collectionPage(from: page(defaultStatus: "LIKE", toggledStatus: "INDIFFERENT"),
                                      isAlbum: true)
        XCTAssertEqual(parsed.savedToLibrary, false)
        XCTAssertEqual(parsed.libraryTargetPlaylistId, "OLAK5uy_test")
    }

    /// Playlists have no such toggle — the UI keys off nil to hide the button.
    func testPlaylistPageHasNoLibraryState() {
        let parsed = P.collectionPage(from: JSONValue(any: ["contents": [:]]), isAlbum: false)
        XCTAssertNil(parsed.savedToLibrary)
        XCTAssertNil(parsed.libraryTargetPlaylistId)
    }
}
