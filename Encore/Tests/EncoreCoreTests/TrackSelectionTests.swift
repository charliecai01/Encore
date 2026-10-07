import XCTest
@testable import EncoreCore

final class TrackSelectionTests: XCTestCase {

    private let ids = ["a", "b", "c", "d", "e"]

    func testToggleAddsThenRemovesAndMovesAnchor() {
        var (sel, anchor) = TrackSelection.apply(.toggle, at: 1, in: ids, selection: [], anchor: nil)
        XCTAssertEqual(sel, ["b"])
        XCTAssertEqual(anchor, "b")
        (sel, anchor) = TrackSelection.apply(.toggle, at: 1, in: ids, selection: sel, anchor: anchor)
        XCTAssertEqual(sel, [])
        XCTAssertEqual(anchor, "b")
    }

    func testRangeSelectsForwardFromAnchor() {
        let (sel, anchor) = TrackSelection.apply(.range, at: 3, in: ids, selection: ["b"], anchor: "b")
        XCTAssertEqual(sel, ["b", "c", "d"])
        XCTAssertEqual(anchor, "b")
    }

    func testRangeSelectsBackwardFromAnchorAndKeepsOthers() {
        let (sel, _) = TrackSelection.apply(.range, at: 0, in: ids, selection: ["c", "e"], anchor: "c")
        XCTAssertEqual(sel, ["a", "b", "c", "e"])
    }

    func testRangeWithoutAnchorSelectsOnlyClickedRow() {
        let (sel, anchor) = TrackSelection.apply(.range, at: 2, in: ids, selection: [], anchor: nil)
        XCTAssertEqual(sel, ["c"])
        XCTAssertEqual(anchor, "c")
    }

    func testRangeWithStaleAnchorFallsBackToClickedRow() {
        let (sel, anchor) = TrackSelection.apply(.range, at: 4, in: ids, selection: [], anchor: "gone")
        XCTAssertEqual(sel, ["e"])
        XCTAssertEqual(anchor, "e")
    }

    func testOutOfRangeIndexIsNoOp() {
        let (sel, anchor) = TrackSelection.apply(.toggle, at: 9, in: ids, selection: ["a"], anchor: "a")
        XCTAssertEqual(sel, ["a"])
        XCTAssertEqual(anchor, "a")
    }
}
