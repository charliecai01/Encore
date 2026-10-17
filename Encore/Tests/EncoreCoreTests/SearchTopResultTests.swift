import XCTest
@testable import EncoreCore

/// The search top hit is dropped when the result rows already have it —
/// reported live 2026-10-17: "anti-hero" showed the music video as the top
/// hit directly above the song as the first result row.
final class SearchTopResultTests: XCTestCase {

    private let swift = Ref(name: "Taylor Swift", id: "UCqECaJ8Gagnn7YCbPEzWH6g")

    func testMusicVideoTopHitDuplicatesItsSongRow() {
        let video = Track(videoId: "b1kbLwvqugk", title: "Anti-Hero (Official Music Video)",
                          artists: [swift], isVideo: true)
        let song = Track(videoId: "3YgtjHZyCIQ", title: "Anti-Hero", artists: [swift])
        XCTAssertTrue(P.isDuplicate(.track(video), of: [.track(song)]))
    }

    func testSameVideoIdIsADuplicate() {
        let song = Track(videoId: "3YgtjHZyCIQ", title: "Anti-Hero", artists: [swift])
        XCTAssertTrue(P.isDuplicate(.track(song), of: [.track(song)]))
    }

    func testCJKVideoWithEnglishSubtitleAndCreditDuplicatesItsSongRow() {
        let jay = "UCL2MDNdwEtV6aYUgNjFQGZA"
        let video = Track(videoId: "v", title: "晴天 - Sunny Day", artists: [Ref(name: "Jay Chou", id: jay)])
        let song = Track(videoId: "s", title: "晴天", artists: [Ref(name: "周杰倫", id: jay)])
        XCTAssertTrue(P.isDuplicate(.track(video), of: [.track(song)]))
    }

    func testSameTitleByAnotherArtistIsNotADuplicate() {
        let top = Track(videoId: "a", title: "Anti-Hero", artists: [swift])
        let other = Track(videoId: "b", title: "Anti-Hero", artists: [Ref(name: "Anti-Heros")])
        XCTAssertFalse(P.isDuplicate(.track(top), of: [.track(other)]))
    }

    func testArtistCardTopHitStaysWhenRowsDontHaveIt() {
        let card = CardItem(kind: .artist, title: "Taylor Swift", subtitle: "Artist",
                            browseId: "UCqECaJ8Gagnn7YCbPEzWH6g")
        let song = Track(videoId: "3YgtjHZyCIQ", title: "Anti-Hero", artists: [swift])
        XCTAssertFalse(P.isDuplicate(.card(card), of: [.track(song)]))
        XCTAssertTrue(P.isDuplicate(.card(card), of: [.card(card)]))
    }

    func testBaseTitleDropsTrailingQualifiers() {
        XCTAssertEqual(P.baseTitle("Anti-Hero (Official Music Video)"), "anti-hero")
        XCTAssertEqual(P.baseTitle("Anti-Hero [Lyric Video]"), "anti-hero")
        XCTAssertEqual(P.baseTitle("Anti-Hero"), "anti-hero")
        XCTAssertEqual(P.baseTitle("晴天 - Sunny Day"), "晴天")
    }
}

/// Musixmatch's anonymous token now gets a decoy answer for every query —
/// Drake's "NOKIA" with generated gibberish lyrics. Reported live
/// 2026-10-17 under "Anti-Hero".
final class MusixmatchMatchTests: XCTestCase {

    private let antiHero = Track(videoId: "3YgtjHZyCIQ", title: "Anti-Hero",
                                 artists: [Ref(name: "Taylor Swift")], durationSeconds: 201)

    func testRejectsTheDecoyTrack() {
        let decoy = JSONValue(any: ["track_name": "NOKIA", "artist_name": "Drake"])
        XCTAssertFalse(Musixmatch.isPlausibleMatch(decoy, for: antiHero))
    }

    func testRejectsAMissingMatch() {
        XCTAssertFalse(Musixmatch.isPlausibleMatch(.null, for: antiHero))
    }

    func testAcceptsTheRealTrack() {
        let real = JSONValue(any: ["track_name": "Anti-Hero", "artist_name": "Taylor Swift"])
        XCTAssertTrue(Musixmatch.isPlausibleMatch(real, for: antiHero))
    }

    func testAcceptsAVideoTitleAgainstTheSongName() {
        let video = Track(videoId: "b1kbLwvqugk", title: "Anti-Hero (Official Music Video)",
                          artists: [Ref(name: "Taylor Swift")])
        let real = JSONValue(any: ["track_name": "Anti-Hero", "artist_name": "Taylor Swift"])
        XCTAssertTrue(Musixmatch.isPlausibleMatch(real, for: video))
    }
}
