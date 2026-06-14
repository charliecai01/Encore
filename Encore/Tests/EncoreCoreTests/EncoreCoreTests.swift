import XCTest
@testable import EncoreCore

final class EncoreCoreTests: XCTestCase {

    // MARK: - Podcast duration parsing

    func testParsePodcastDuration() {
        XCTAssertEqual(P.parsePodcastDuration("1 hr 1 min"), 3660)
        XCTAssertEqual(P.parsePodcastDuration("32 min"), 1920)
        XCTAssertEqual(P.parsePodcastDuration("45 sec"), 45)
        XCTAssertEqual(P.parsePodcastDuration("1 hr"), 3600)
        XCTAssertEqual(P.parsePodcastDuration("2 hours 5 minutes"), 7500)
        XCTAssertEqual(P.parsePodcastDuration("90 seconds"), 90)
    }

    func testParsePodcastDurationRejectsGarbage() {
        XCTAssertNil(P.parsePodcastDuration(""))
        XCTAssertNil(P.parsePodcastDuration("coming soon"))
    }

    // MARK: - Podcast episode parsing

    func testPodcastEpisodeParsing() {
        let json = """
        {
          "musicMultiRowListItemRenderer": {
            "title": { "runs": [{ "text": "Episode One" }] },
            "subtitle": { "runs": [{ "text": "6d ago" }] },
            "description": { "runs": [{ "text": "Show notes here" }] },
            "playbackProgress": {
              "musicPlaybackProgressRenderer": {
                "durationText": { "runs": [{ "text": "1 hr 1 min" }] }
              }
            },
            "onTap": { "watchEndpoint": { "videoId": "ABC123" } }
          }
        }
        """
        let root = JSONValue.parse(Data(json.utf8))
        let thumb = URL(string: "https://example.com/show.jpg")!
        let eps = P.podcastEpisodes(from: root, showTitle: "My Show", showThumb: thumb)

        XCTAssertEqual(eps.count, 1)
        let ep = try! XCTUnwrap(eps.first)
        XCTAssertEqual(ep.videoId, "ABC123")
        XCTAssertEqual(ep.title, "Episode One")
        XCTAssertEqual(ep.artistLine, "My Show")
        XCTAssertTrue(ep.isEpisode)
        XCTAssertEqual(ep.dateText, "6d ago")
        XCTAssertEqual(ep.details, "Show notes here")
        XCTAssertEqual(ep.durationSeconds, 3660)
        XCTAssertEqual(ep.thumbnailURL, thumb)
    }

    // MARK: - Track Codable tolerance (old caches lack episode fields)

    func testTrackDecodesLegacyPayloadWithoutEpisodeFields() throws {
        let legacy = """
        { "videoId": "v1", "title": "Song", "artists": [], "artistLine": "Artist", "durationSeconds": 180 }
        """
        let t = try JSONDecoder().decode(Track.self, from: Data(legacy.utf8))
        XCTAssertEqual(t.videoId, "v1")
        XCTAssertEqual(t.durationSeconds, 180)
        XCTAssertFalse(t.isEpisode)
        XCTAssertNil(t.dateText)
        XCTAssertNil(t.details)
    }

    func testTrackRoundTripsEpisodeFields() throws {
        let original = Track(videoId: "v2", title: "Ep", artistLine: "Show",
                             durationSeconds: 600, isEpisode: true,
                             dateText: "1d ago", details: "notes")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isEpisode)
        XCTAssertEqual(decoded.dateText, "1d ago")
    }

    // MARK: - Duration formatting

    func testDurationFormat() {
        XCTAssertEqual(Track.format(seconds: 185), "3:05")
        XCTAssertEqual(Track.format(seconds: 3723), "1:02:03")
        XCTAssertEqual(Track.format(seconds: 0), "0:00")
    }

    func testLengthText() {
        XCTAssertEqual(Track(videoId: "x", title: "x", durationSeconds: 3660).lengthText, "1 hr 1 min")
        XCTAssertEqual(Track(videoId: "x", title: "x", durationSeconds: 1920).lengthText, "32 min")
        XCTAssertEqual(Track(videoId: "x", title: "x", durationSeconds: 3600).lengthText, "1 hr")
        XCTAssertEqual(Track(videoId: "x", title: "x", durationSeconds: 45).lengthText, "45 sec")
        XCTAssertEqual(Track(videoId: "x", title: "x", durationSeconds: nil).lengthText, "")
    }

    // MARK: - Artwork URL upscaling

    func testArtworkUpscaleRewritesGoogleSize() {
        let url = URL(string: "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj")
        let out = Artwork.upscale(url, to: 300)
        XCTAssertEqual(out?.absoluteString.contains("w300-h300"), true)
    }

    func testArtworkUpscaleLeavesNonGoogleAndNil() {
        let other = URL(string: "https://example.com/cover.jpg")
        XCTAssertEqual(Artwork.upscale(other, to: 300), other)
        XCTAssertNil(Artwork.upscale(nil, to: 300))
    }

    // MARK: - CJK normalization (Simplified ↔ Traditional matching)

    func testCJKTraditionalSimplifiedInterop() {
        XCTAssertEqual(CJK.toTraditional("爱"), "愛")
        XCTAssertEqual(CJK.toSimplified("愛"), "爱")
        // A Traditional title is findable with a Simplified query.
        XCTAssertTrue("愛".matches(normalizedQuery: "爱"))
    }

    func testMatchNormalizedIsCaseInsensitiveAndNonHanStable() {
        XCTAssertEqual("HELLO".matchNormalized, "hello")
        XCTAssertNil(CJK.toTraditional("hello"))
    }
}
