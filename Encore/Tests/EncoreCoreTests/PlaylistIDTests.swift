import XCTest
@testable import EncoreCore

final class PlaylistIDTests: XCTestCase {

    func testStripsVLPrefix() {
        XCTAssertEqual("VLPLabc123".strippingPlaylistVLPrefix, "PLabc123")
    }

    func testLeavesNonVLIdsUntouched() {
        XCTAssertEqual("PLabc123".strippingPlaylistVLPrefix, "PLabc123")
        XCTAssertEqual("".strippingPlaylistVLPrefix, "")
    }
}
