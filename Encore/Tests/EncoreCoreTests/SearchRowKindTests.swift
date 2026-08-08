import XCTest
@testable import EncoreCore

/// Album search rows must parse as CARDS, not tracks.
///
/// They carry a play overlay (the row has a play button) AND a browseEndpoint
/// to the album page. The dispatch used to test the overlay first, so every
/// album result became a `.track` — which dropped the browseId and made album
/// search results impossible to open. Song rows are the counter-case and must
/// keep parsing as tracks.
final class SearchRowKindTests: XCTestCase {

    /// Shaped like a real album search row: browseEndpoint + play overlay,
    /// and no playlistItemData.
    private var albumRow: JSONValue {
        JSONValue(any: [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer":
                        ["text": ["runs": [["text": "HIStory: PAST, PRESENT AND FUTURE, BOOK I"]]]]],
                    ["musicResponsiveListItemFlexColumnRenderer":
                        ["text": ["runs": [["text": "Album • Michael Jackson • 1995"]]]]],
                ],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "MPREb_L7mH5RJKKdI",
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ALBUM"],
                        ],
                    ],
                ],
                "overlay": ["watchEndpoint": ["videoId": "someTrackOnTheAlbum"]],
            ],
        ])
    }

    /// A song search row: playlistItemData, no browseEndpoint.
    private var songRow: JSONValue {
        JSONValue(any: [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "meBHKKdMnGI"],
                "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer":
                        ["text": ["runs": [["text": "Billie Jean"]]]]],
                    ["musicResponsiveListItemFlexColumnRenderer":
                        ["text": ["runs": [["text": "Michael Jackson"]]]]],
                ],
                "overlay": ["watchEndpoint": ["videoId": "meBHKKdMnGI"]],
            ],
        ])
    }

    func testAlbumRowIsACardWithItsBrowseId() throws {
        let items = P.shelfItems(fromContents: [albumRow])
        guard case .card(let card) = try XCTUnwrap(items.first) else {
            return XCTFail("album row parsed as \(items.first as Any) — should be a card")
        }
        XCTAssertEqual(card.kind, .album)
        XCTAssertEqual(card.browseId, "MPREb_L7mH5RJKKdI")
        XCTAssertEqual(card.title, "HIStory: PAST, PRESENT AND FUTURE, BOOK I")
    }

    func testSongRowIsStillATrack() throws {
        let items = P.shelfItems(fromContents: [songRow])
        guard case .track(let track) = try XCTUnwrap(items.first) else {
            return XCTFail("song row parsed as \(items.first as Any) — should be a track")
        }
        XCTAssertEqual(track.videoId, "meBHKKdMnGI")
        XCTAssertEqual(track.title, "Billie Jean")
    }

    func testMixedShelfKeepsBothKinds() {
        let items = P.shelfItems(fromContents: [albumRow, songRow])
        XCTAssertEqual(items.count, 2)
        if case .card = items[0] {} else { XCTFail("first should be a card") }
        if case .track = items[1] {} else { XCTFail("second should be a track") }
    }
}
