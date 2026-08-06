import XCTest
@testable import EncoreCore

final class PlayableQueueTests: XCTestCase {

    private func t(_ id: String, bad: Bool = false) -> Track {
        Track(videoId: id, title: id, isUnavailable: bad)
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
}
