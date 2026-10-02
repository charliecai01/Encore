import XCTest
@testable import EncoreCore

final class PageMemoryTests: XCTestCase {
    private let big = PageMemory.recycleAbove + 1
    private let idle = PageMemory.idleBeforeRecycle + 1

    func testBloatedIdlePageIsRecycled() {
        XCTAssertTrue(PageMemory.shouldRecycle(footprint: big, isPlaying: false,
                                               pausedFor: idle, pageVisible: false))
    }

    /// Never interrupt music to reclaim memory.
    func testNeverRecyclesWhilePlaying() {
        XCTAssertFalse(PageMemory.shouldRecycle(footprint: big, isPlaying: true,
                                                pausedFor: idle, pageVisible: false))
    }

    /// A pause/resume a few seconds apart must not get a reload in between.
    func testWaitsForAProperPause() {
        XCTAssertFalse(PageMemory.shouldRecycle(footprint: big, isPlaying: false,
                                                pausedFor: 5, pageVisible: false))
    }

    /// The video panel renders the page itself — reloading would blank it.
    func testNeverRecyclesAVisiblePage() {
        XCTAssertFalse(PageMemory.shouldRecycle(footprint: big, isPlaying: false,
                                                pausedFor: idle, pageVisible: true))
    }

    func testHealthyOrUnknownFootprintIsLeftAlone() {
        XCTAssertFalse(PageMemory.shouldRecycle(footprint: PageMemory.recycleAbove, isPlaying: false,
                                                pausedFor: idle, pageVisible: false))
        XCTAssertFalse(PageMemory.shouldRecycle(footprint: nil, isPlaying: false,
                                                pausedFor: idle, pageVisible: false))
    }
}
