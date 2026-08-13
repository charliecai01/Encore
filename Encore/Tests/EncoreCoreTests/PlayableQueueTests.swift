import XCTest
@testable import EncoreCore

final class PlayableQueueTests: XCTestCase {

    private func t(_ id: String, bad: Bool = false) -> Track {
        Track(videoId: id, title: id, isUnavailable: bad)
    }

    /// A distinct-videoId track carrying an explicit title/artist, for the
    /// adjacent-duplicate tests below (unlike `t()`, whose title is just the id).
    private func song(_ id: String, title: String, artist: String) -> Track {
        Track(videoId: id, title: title, artistLine: artist)
    }

    func testDropsUnavailableAndKeepsTheTappedTrack() {
        let input = [t("a"), t("bad1", bad: true), t("b"), t("c")]
        let (q, start) = PlayableQueue.build(input, startAt: 2)   // tapped "b"
        XCTAssertEqual(q.map(\.videoId), ["a", "b", "c"])
        XCTAssertEqual(q[start].videoId, "b")
    }

    func testTappingAnUnavailableRowStartsAtTheNextPlayable() {
        let input = [t("a"), t("bad", bad: true), t("b")]
        let (q, start) = PlayableQueue.build(input, startAt: 1)   // tapped the grey row
        XCTAssertEqual(q[start].videoId, "b")
    }

    func testConsecutiveUnavailableRunIsSkippedWholesale() {
        // Charlie's real case: three greyed tracks in a row.
        let input = [t("a"), t("x", bad: true), t("y", bad: true), t("z", bad: true), t("b")]
        let (q, start) = PlayableQueue.build(input, startAt: 1)
        XCTAssertEqual(q.map(\.videoId), ["a", "b"])
        XCTAssertEqual(q[start].videoId, "b")
    }

    func testTailAllUnavailableFallsBackToLastPlayable() {
        let input = [t("a"), t("b"), t("bad", bad: true)]
        let (q, start) = PlayableQueue.build(input, startAt: 2)
        XCTAssertEqual(q[start].videoId, "b")
    }

    func testNothingPlayableYieldsEmptyQueue() {
        let (q, start) = PlayableQueue.build([t("x", bad: true), t("y", bad: true)], startAt: 0)
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(start, 0)
    }

    func testAllAvailableIsUnchanged() {
        let input = [t("a"), t("b"), t("c")]
        let (q, start) = PlayableQueue.build(input, startAt: 2)
        XCTAssertEqual(q.map(\.videoId), ["a", "b", "c"])
        XCTAssertEqual(start, 2)
    }

    func testDuplicateIdsRemapByPositionNotIdentity() {
        // Same videoId twice: the second tap must land on the second copy.
        let input = [t("dup"), t("bad", bad: true), t("dup")]
        let (q, start) = PlayableQueue.build(input, startAt: 2)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(start, 1)
    }

    func testOutOfRangeStartIsClamped() {
        let input = [t("a"), t("b")]
        let (q, start) = PlayableQueue.build(input, startAt: 99)
        XCTAssertEqual(q.count, 2)
        XCTAssertTrue(q.indices.contains(start))
    }

    // MARK: - Adjacent exact duplicates (Charlie's real case: 他不慣被愛 by 衛蘭,
    // two library entries, different videoIds, adjacent once sorted by artist)

    func testAdjacentDuplicateIsCollapsed() {
        let input = [
            song("a", title: "Intro", artist: "X"),
            song("dup1", title: "他不慣被愛", artist: "衛蘭"),
            song("dup2", title: "他不慣被愛", artist: "衛蘭"),
            song("b", title: "Outro", artist: "X"),
        ]
        let (q, start) = PlayableQueue.build(input, startAt: 0)
        XCTAssertEqual(q.map(\.videoId), ["a", "dup1", "b"],
                       "the second copy must not survive to play right after the first")
        XCTAssertEqual(start, 0)
    }

    func testTappingTheSecondCopyStillPlaysIt() {
        // The user explicitly chose the SECOND copy — it must play, not the
        // first, even though the pair would otherwise collapse to one.
        let input = [
            song("dup1", title: "他不慣被愛", artist: "衛蘭"),
            song("dup2", title: "他不慣被愛", artist: "衛蘭"),
        ]
        let (q, start) = PlayableQueue.build(input, startAt: 1)
        XCTAssertEqual(q.map(\.videoId), ["dup1", "dup2"])
        XCTAssertEqual(q[start].videoId, "dup2")
    }

    func testTappingTheFirstCopyDropsTheSecond() {
        let input = [
            song("dup1", title: "他不慣被愛", artist: "衛蘭"),
            song("dup2", title: "他不慣被愛", artist: "衛蘭"),
            song("b", title: "Next", artist: "X"),
        ]
        let (q, start) = PlayableQueue.build(input, startAt: 0)
        XCTAssertEqual(q.map(\.videoId), ["dup1", "b"])
        XCTAssertEqual(start, 0)
    }

    func testThreeCopiesInARowCollapseToOne() {
        let input = (0..<3).map { song("d\($0)", title: "他不慣被愛", artist: "衛蘭") }
            + [song("b", title: "Next", artist: "X")]
        let (q, _) = PlayableQueue.build(input, startAt: 0)
        XCTAssertEqual(q.map(\.videoId), ["d0", "b"])
    }

    /// A parenthetical suffix is a genuinely different recording, not a
    /// duplicate — must never be collapsed even though it shares a prefix.
    func testDifferentVersionsAreNotCollapsed() {
        let input = [
            song("a", title: "我喜歡 - I Like It", artist: "David Tao"),
            song("b", title: "我喜歡 (Ballad Version) - I Like It (Ballad Version)", artist: "David Tao"),
        ]
        let (q, _) = PlayableQueue.build(input, startAt: 0)
        XCTAssertEqual(q.count, 2)
    }

    /// Same title, different artist (a cover) is not a duplicate.
    func testSameTitleDifferentArtistIsNotCollapsed() {
        let input = [
            song("a", title: "Yesterday", artist: "The Beatles"),
            song("b", title: "Yesterday", artist: "Boyz II Men"),
        ]
        let (q, _) = PlayableQueue.build(input, startAt: 0)
        XCTAssertEqual(q.count, 2)
    }

    /// Same song appearing twice but NOT adjacent (elsewhere in a long
    /// playlist) never gets collapsed — only back-to-back pairs sound like a
    /// repeat, so only those are touched.
    func testNonAdjacentDuplicatesAreUntouched() {
        let input = [
            song("dup1", title: "他不慣被愛", artist: "衛蘭"),
            song("mid", title: "Middle", artist: "X"),
            song("dup2", title: "他不慣被愛", artist: "衛蘭"),
        ]
        let (q, _) = PlayableQueue.build(input, startAt: 0)
        XCTAssertEqual(q.map(\.videoId), ["dup1", "mid", "dup2"])
    }

    func testDuplicateAndUnavailableComposeCorrectly() {
        // dup2 duplicates dup1 AND would need to survive past an unavailable
        // row in between — both filters must compose without losing track of
        // adjacency (unavailable rows don't count as "in between" for dedup).
        let input = [
            song("dup1", title: "他不慣被愛", artist: "衛蘭"),
            t("bad", bad: true),
            song("dup2", title: "他不慣被愛", artist: "衛蘭"),
        ]
        let (q, _) = PlayableQueue.build(input, startAt: 0)
        XCTAssertEqual(q.map(\.videoId), ["dup1"])
    }
}
