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

    // MARK: - LibrarySort: track ordering

    private func sampleTracks() -> [Track] {
        [
            Track(videoId: "1", title: "Banana", artistLine: "Zed", album: Ref(name: "Yellow")),
            Track(videoId: "2", title: "apple", artistLine: "alpha", album: Ref(name: "Box")),
            Track(videoId: "3", title: "Cherry", artistLine: "Mike", album: nil),
        ]
    }

    func testTrackSortSourceAndReversed() {
        let t = sampleTracks()
        XCTAssertEqual(LibrarySort.sort(t, by: .source).map(\.videoId), ["1", "2", "3"])
        XCTAssertEqual(LibrarySort.sort(t, by: .reversed).map(\.videoId), ["3", "2", "1"])
    }

    func testTrackSortTitleIsCaseInsensitive() {
        // "apple" must sort before "Banana" despite lowercase.
        XCTAssertEqual(LibrarySort.sort(sampleTracks(), by: .title).map(\.title),
                       ["apple", "Banana", "Cherry"])
    }

    func testTrackSortArtist() {
        XCTAssertEqual(LibrarySort.sort(sampleTracks(), by: .artist).map(\.artistLine),
                       ["alpha", "Mike", "Zed"])
    }

    func testTrackSortAlbumPutsMissingLast() {
        // nil album ("~") sorts last; "Box" before "Yellow".
        XCTAssertEqual(LibrarySort.sort(sampleTracks(), by: .album).map(\.videoId),
                       ["2", "1", "3"])
    }

    // MARK: - LibrarySort: personal play-count ordering

    func testMostAndLeastPlayedUsePersonalCounts() {
        let suite = UserDefaults(suiteName: "PlayCountSortTests")!
        suite.removePersistentDomain(forName: "PlayCountSortTests")
        let prev = PlayCounts.store
        PlayCounts.store = suite
        defer { PlayCounts.store = prev }

        let t = sampleTracks()   // ids 1 (Banana), 2 (apple), 3 (Cherry)
        // Play "Cherry" 3x and "Banana" once; "apple" is never played.
        for _ in 0..<3 { PlayCounts.record(t[2]) }
        PlayCounts.record(t[0])

        XCTAssertEqual(LibrarySort.sort(t, by: .mostPlayed).map(\.videoId), ["3", "1", "2"])
        // Never-played first — the point of Least Played.
        XCTAssertEqual(LibrarySort.sort(t, by: .leastPlayed).map(\.videoId), ["2", "1", "3"])
    }

    func testPlayCountSortTieBreaksByTitle() {
        let suite = UserDefaults(suiteName: "PlayCountSortTiesTests")!
        suite.removePersistentDomain(forName: "PlayCountSortTiesTests")
        let prev = PlayCounts.store
        PlayCounts.store = suite
        defer { PlayCounts.store = prev }
        // All zero plays -> alphabetical, deterministic (not source order).
        XCTAssertEqual(LibrarySort.sort(sampleTracks(), by: .mostPlayed).map(\.title),
                       ["apple", "Banana", "Cherry"])
    }

    // MARK: - LibrarySort: filtering (CJK-aware)

    func testTrackFilterMatchesTitleArtistAlbum() {
        let t = sampleTracks()
        XCTAssertEqual(LibrarySort.filter(t, query: "cherry").map(\.videoId), ["3"])
        XCTAssertEqual(LibrarySort.filter(t, query: "alpha").map(\.videoId), ["2"])
        XCTAssertEqual(LibrarySort.filter(t, query: "yellow").map(\.videoId), ["1"])
        XCTAssertEqual(LibrarySort.filter(t, query: "   ").count, 3) // blank = no filter
    }

    func testTrackFilterIsScriptInsensitive() {
        let t = [Track(videoId: "x", title: "愛", artistLine: "歌手")]
        // Simplified query finds the Traditional title.
        XCTAssertEqual(LibrarySort.filter(t, query: "爱").count, 1)
    }

    // MARK: - LibrarySort: cards

    private func sampleCards() -> [CardItem] {
        [
            CardItem(kind: .album, title: "Zebra", subtitle: "Beta"),
            CardItem(kind: .album, title: "apron", subtitle: "Alpha"),
        ]
    }

    func testCardSortTitleAndSubtitle() {
        XCTAssertEqual(LibrarySort.sortCards(sampleCards(), by: .title).map(\.title), ["apron", "Zebra"])
        // Sort by subtitle (e.g. the Albums tab "Artist" sort) — Alpha before Beta.
        XCTAssertEqual(LibrarySort.sortCards(sampleCards(), by: .subtitle).map(\.title), ["apron", "Zebra"])
    }

    // MARK: - PlayedEpisodes

    func testPlayedEpisodes() {
        let suite = UserDefaults(suiteName: "test.played.\(UUID().uuidString)")!
        let prev = PlayedEpisodes.store
        PlayedEpisodes.store = suite
        defer { PlayedEpisodes.store = prev }

        XCTAssertFalse(PlayedEpisodes.isPlayed("a"))
        PlayedEpisodes.set("a", played: true)
        XCTAssertTrue(PlayedEpisodes.isPlayed("a"))
        XCTAssertEqual(PlayedEpisodes.all(), ["a"])
        PlayedEpisodes.toggle("a")
        XCTAssertFalse(PlayedEpisodes.isPlayed("a"))
        PlayedEpisodes.toggle("b")
        XCTAssertEqual(PlayedEpisodes.all(), ["b"])
    }

    // MARK: - Discovery

    func testDiscoveryCuratePrefersCrossLanguageAndExcludes() {
        var pool = (0..<10).map { Track(videoId: "e\($0)", title: "Eng \($0)", artistLine: "Artist") }
        pool.append(Track(videoId: "c1", title: "小鎮姑娘", artistLine: "陶喆")) // CJK, should be dropped
        pool.append(Track(videoId: "e0", title: "dup", artistLine: "Artist"))   // duplicate id
        // Mostly-CJK listener → prefer English; "e1" is already known (excluded).
        let out = Discovery.curate(candidates: pool, exclude: ["e1"], preferNonCJK: true, limit: 20)
        XCTAssertFalse(out.contains { $0.videoId == "e1" })            // excluded
        XCTAssertFalse(out.contains { Discovery.isCJK($0) })           // cross-language
        XCTAssertEqual(Set(out.map(\.videoId)).count, out.count)       // deduped
        XCTAssertEqual(out.count, 9)                                   // 10 english − 1 excluded
    }

    func testDiscoveryFallsBackWhenPreferredTooThin() {
        let cn = (0..<10).map { Track(videoId: "c\($0)", title: "歌\($0)", artistLine: "歌手") }
        // Want English but pool is all Chinese → fall back to fresh picks, not empty.
        let out = Discovery.curate(candidates: cn, exclude: [], preferNonCJK: true, limit: 5)
        XCTAssertEqual(out.count, 5)
    }

    func testDiscoveryExcludesEpisodes() {
        let song = Track(videoId: "s", title: "Song", artistLine: "A")
        let ep = Track(videoId: "p", title: "Ep", artistLine: "Show", isEpisode: true)
        let out = Discovery.curate(candidates: [song, ep], exclude: [], preferNonCJK: true, limit: 10)
        XCTAssertEqual(out.map(\.videoId), ["s"])
    }

    func testCardArrangeFilterThenReverse() {
        let cards = sampleCards()
        XCTAssertEqual(LibrarySort.arrangeCards(cards, query: "beta", order: .source).map(\.title), ["Zebra"])
        XCTAssertEqual(LibrarySort.sortCards(cards, by: .reversed).map(\.title), ["apron", "Zebra"])
    }
}
