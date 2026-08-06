import XCTest
@testable import EncoreCore

/// Guards the "grey row" signal. Charlie's "Favorite Songs" holds three of
/// these (JJ Lin "The Key" / "Twilight", 蔡依林 "你怎麼連話都說不清楚"); playing
/// them returns player error 150 and the rapid skip-skip-skip that reads as the
/// player jumping around. The parse is what lets both apps refuse the tap.
final class UnavailableTrackTests: XCTestCase {

    /// A row shaped like the real thing, with the policy YouTube actually sends.
    private func row(policy: String?) -> JSONValue {
        var dict: [String: Any] = [
            "playlistItemData": ["videoId": "uzsSx-xE8NY"],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer":
                    ["text": ["runs": [["text": "The Key"]]]]],
                ["musicResponsiveListItemFlexColumnRenderer":
                    ["text": ["runs": [["text": "JJ Lin"]]]]],
            ],
        ]
        if let policy { dict["musicItemRendererDisplayPolicy"] = policy }
        return JSONValue(any: dict)
    }

    func testGreyOutPolicyMarksTrackUnavailable() throws {
        let t = try XCTUnwrap(P.track(fromMRLIR: row(policy: "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT")))
        XCTAssertTrue(t.isUnavailable)
        XCTAssertEqual(t.title, "The Key")
    }

    func testNormalRowIsAvailable() throws {
        let t = try XCTUnwrap(P.track(fromMRLIR: row(policy: nil)))
        XCTAssertFalse(t.isUnavailable)
    }

    func testUnrelatedPolicyIsNotTreatedAsUnavailable() throws {
        let t = try XCTUnwrap(P.track(fromMRLIR: row(policy: "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_DEFAULT")))
        XCTAssertFalse(t.isUnavailable)
    }

    // MARK: - Codable round-trip (the disk cache stores Tracks)

    func testFlagSurvivesEncodeDecode() throws {
        let t = Track(videoId: "x", title: "y", isUnavailable: true)
        let back = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(t))
        XCTAssertTrue(back.isUnavailable)
    }

    /// Caches written before this field existed must still decode.
    func testLegacyCachedTrackWithoutTheFieldDecodes() throws {
        let legacy = #"{"videoId":"abc","title":"Old","artists":[],"artistLine":"A","isEpisode":false,"isVideo":false}"#
        let t = try JSONDecoder().decode(Track.self, from: Data(legacy.utf8))
        XCTAssertFalse(t.isUnavailable)
        XCTAssertEqual(t.videoId, "abc")
    }
}
