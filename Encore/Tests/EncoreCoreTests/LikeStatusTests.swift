import XCTest
@testable import EncoreCore

/// A heart must mean "thumbed up", not "in your library".
///
/// `FEmusic_liked_videos` — which the apps used to seed `likedIds` wholesale —
/// also contains every track of every album added to the library. Saving MJ's
/// HIStory put a filled heart on all 30 of its songs, none of which were liked
/// (every row reported likeStatus INDIFFERENT, and none were in the Liked Music
/// playlist). The row's own likeStatus is the trustworthy source.
final class LikeStatusTests: XCTestCase {

    private func row(likeStatus: String?) -> JSONValue {
        var menu: [String: Any] = [:]
        if let likeStatus {
            menu = ["menu": ["menuRenderer": ["items": [
                ["toggleMenuServiceItemRenderer": ["likeStatus": likeStatus]],
            ]]]]
        }
        var dict: [String: Any] = [
            "playlistItemData": ["videoId": "vid1"],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer":
                    ["text": ["runs": [["text": "Billie Jean"]]]]],
            ],
        ]
        menu.forEach { dict[$0.key] = $0.value }
        return JSONValue(any: dict)
    }

    func testLikedRowParsesAsLiked() throws {
        let t = try XCTUnwrap(P.track(fromMRLIR: row(likeStatus: "LIKE")))
        XCTAssertEqual(t.isLiked, true)
    }

    func testIndifferentRowParsesAsNotLiked() throws {
        let t = try XCTUnwrap(P.track(fromMRLIR: row(likeStatus: "INDIFFERENT")))
        XCTAssertEqual(t.isLiked, false,
                       "an album track you never thumbed up must not show a heart")
    }

    func testDislikedRowIsNotLiked() throws {
        let t = try XCTUnwrap(P.track(fromMRLIR: row(likeStatus: "DISLIKE")))
        XCTAssertEqual(t.isLiked, false)
    }

    /// Absent means "don't know" — not "not liked" — so it can't wipe state.
    func testRowWithoutLikeStatusIsUnknown() throws {
        let t = try XCTUnwrap(P.track(fromMRLIR: row(likeStatus: nil)))
        XCTAssertNil(t.isLiked)
    }

    func testFlagSurvivesTheDiskCache() throws {
        let t = Track(videoId: "x", title: "y", isLiked: true)
        let back = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.isLiked, true)
    }

    func testLegacyCachedTrackDecodesAsUnknown() throws {
        let legacy = #"{"videoId":"abc","title":"Old","artists":[],"artistLine":"A","isEpisode":false,"isVideo":false}"#
        XCTAssertNil(try JSONDecoder().decode(Track.self, from: Data(legacy.utf8)).isLiked)
    }
}
