import XCTest
@testable import EncoreCore

/// Guards `NetEase.pickBestMatch` against attaching an unrelated song's
/// lyrics to a track. Reported live 2026-08-14: Charlie's Now Playing
/// screen showed Mandarin lyrics ("丑八怪") under "Take Off" by the indie
/// artist Jackson Whalan. Re-querying NetEase's search for that exact
/// title+artist returned five real "Take Off" results — none of them by
/// Jackson Whalan, none duration-matching within 4s either — which is what
/// the fixtures below are built from.
final class NetEaseMatchTests: XCTestCase {

    private func song(id: Int, name: String, artist: String, durationMs: Int) -> JSONValue {
        JSONValue(any: [
            "id": id,
            "name": name,
            "duration": durationMs,
            "artists": [["name": artist]],
        ])
    }

    /// The actual unrelated candidates NetEase returned for this query.
    private var unrelatedCandidates: [JSONValue] {
        [
            song(id: 564426435, name: "Take Off", artist: "San Jackson Band", durationMs: 247_400),
            song(id: 554913543, name: "Take Off", artist: "San Jackson Band", durationMs: 247_400),
            song(id: 1_453_768_415, name: "Take Off", artist: "Rodney Jackson", durationMs: 227_100),
            song(id: 2_088_062_994, name: "Take Off", artist: "$co Jackson!", durationMs: 113_100),
            song(id: 3_411_857_892, name: "Watching aliens take off and flyyy", artist: "Jason Jackson", durationMs: 215_000),
        ]
    }

    private var jacksonWhalanTrack: Track {
        Track(videoId: "x", title: "Take Off", artists: [Ref(name: "Jackson Whalan")],
              artistLine: "Jackson Whalan", durationSeconds: 166)
    }

    func testDoesNotAttachAnUnrelatedArtistsSongEvenWithATitleMatch() {
        // Every candidate is literally titled "Take Off" or close to it, so a
        // title-only check would wrongly accept one — the artist mismatch
        // must be what disqualifies them all.
        XCTAssertNil(NetEase.pickBestMatch(unrelatedCandidates, for: jacksonWhalanTrack))
    }

    func testAcceptsATrueArtistAndTitleMatch() {
        let correct = song(id: 999, name: "Take Off", artist: "Jackson Whalan", durationMs: 166_000)
        let songs = unrelatedCandidates + [correct]
        XCTAssertEqual(NetEase.pickBestMatch(songs, for: jacksonWhalanTrack), 999)
    }

    func testAcceptsAnExactDurationMatchEvenWithATitleVariant() {
        // A legitimate alternate title (e.g. a live/remaster suffix) paired
        // with an exact duration is still good evidence of the same song.
        let variant = song(id: 42, name: "Take Off (Live)", artist: "Jackson Whalan", durationMs: 166_200)
        XCTAssertEqual(NetEase.pickBestMatch([variant], for: jacksonWhalanTrack), 42)
    }

    func testEmptyResultsMatchNothing() {
        XCTAssertNil(NetEase.pickBestMatch([], for: jacksonWhalanTrack))
    }

    func testCJKTitleMatchesAcrossSimplifiedTraditional() {
        // matchNormalized folds Traditional → Simplified, so a Traditional
        // search hit must still match a Simplified-titled track.
        let track = Track(videoId: "y", title: "丑八怪", artists: [Ref(name: "李荣浩")],
                           artistLine: "李荣浩", durationSeconds: 200)
        let hit = song(id: 7, name: "醜八怪", artist: "李榮浩", durationMs: 199_800)
        XCTAssertEqual(NetEase.pickBestMatch([hit], for: track), 7)
    }
}
