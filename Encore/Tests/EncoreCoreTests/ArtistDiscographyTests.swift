import XCTest
@testable import EncoreCore

/// An artist's "Albums" carousel only carries ~10 releases; its "More" link
/// (an MPAD… discography browse + params) is what lets `YTM.artist` pull the
/// full list. Shapes match the live page (probed 2026-10-01, Taylor Swift).
final class ArtistDiscographyTests: XCTestCase {
    private func carousel(title: String, more: [String: Any]?) -> [String: Any] {
        var header: [String: Any] = ["title": ["runs": [["text": title]]]]
        if let more {
            header["moreContentButton"] = ["buttonRenderer": [
                "navigationEndpoint": ["browseEndpoint": more]]]
        }
        return ["musicCarouselShelfRenderer": [
            "header": ["musicCarouselShelfBasicHeaderRenderer": header],
            "contents": [["musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Red"]]],
                "subtitle": ["runs": [["text": "2012"]]],
                "navigationEndpoint": ["browseEndpoint": ["browseId": "MPREb_red"]],
            ]]],
        ]]
    }

    private func page(_ shelves: [[String: Any]]) -> JSONValue {
        JSONValue(any: ["contents": ["sectionListRenderer": ["contents": shelves]]])
    }

    func testAlbumsCarouselKeepsDiscographyEndpoint() {
        let shelves = P.shelves(from: page([
            carousel(title: "Albums", more: ["browseId": "MPADUCabc", "params": "ggMIegYIARoCAQI%3D"]),
        ]))
        XCTAssertEqual(shelves.first?.discographyEndpoint?.browseId, "MPADUCabc")
        XCTAssertEqual(shelves.first?.discographyEndpoint?.params, "ggMIegYIARoCAQI%3D")
    }

    func testNonDiscographyMoreLinksAreIgnored() {
        let shelves = P.shelves(from: page([
            carousel(title: "Videos", more: ["browseId": "VLOLAKxyz", "params": "ggMCCAI%3D"]),
            carousel(title: "Fans might also like", more: nil),
        ]))
        XCTAssertEqual(shelves.count, 2)
        XCTAssertNil(shelves[0].moreBrowseId, "a Videos 'More' must not light up track-shelf 'Show all'")
        XCTAssertNil(shelves[0].discographyEndpoint)
        XCTAssertNil(shelves[1].discographyEndpoint)
    }
}
