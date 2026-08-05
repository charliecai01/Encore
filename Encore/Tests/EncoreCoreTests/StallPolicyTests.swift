import XCTest
@testable import EncoreCore

/// Guards the weak-cellular stall behavior. The regression these exist to stop:
/// reloading a player that is actively buffering, which restarts the download
/// and — on a link slow enough that re-buffering exceeds the threshold — loops
/// forever without ever playing.
final class StallPolicyTests: XCTestCase {

    // MARK: - Buffering must never be reloaded out from under itself

    func testBufferingPlayerIsLeftAloneWellPastTheNormalReloadThreshold() {
        // 20s frozen would be two reloads deep if we ignored buffering.
        XCTAssertEqual(
            StallPolicy.action(frozen: 20, buffering: true,
                               consecutiveReloads: 0, alreadyNudged: false),
            .none)
    }

    func testBufferingPlayerIsNotEvenNudged() {
        XCTAssertEqual(
            StallPolicy.action(frozen: 6, buffering: true,
                               consecutiveReloads: 0, alreadyNudged: false),
            .none)
    }

    func testWedgedBufferingPlayerEventuallyReloads() {
        // The escape hatch: "buffering" forever is a dead stream, not a slow one.
        XCTAssertEqual(
            StallPolicy.action(frozen: StallPolicy.bufferingReloadAfter + 1,
                               buffering: true,
                               consecutiveReloads: 0, alreadyNudged: false),
            .reload)
    }

    // MARK: - A genuinely stuck (non-buffering) player still recovers

    func testShortFreezeDoesNothing() {
        XCTAssertEqual(
            StallPolicy.action(frozen: 2, buffering: false,
                               consecutiveReloads: 0, alreadyNudged: false),
            .none)
    }

    func testModerateFreezeNudgesOnce() {
        XCTAssertEqual(
            StallPolicy.action(frozen: 5, buffering: false,
                               consecutiveReloads: 0, alreadyNudged: false),
            .nudge)
        // …and only once per stall.
        XCTAssertEqual(
            StallPolicy.action(frozen: 5, buffering: false,
                               consecutiveReloads: 0, alreadyNudged: true),
            .none)
    }

    func testLongFreezeReloads() {
        XCTAssertEqual(
            StallPolicy.action(frozen: 10, buffering: false,
                               consecutiveReloads: 0, alreadyNudged: true),
            .reload)
    }

    // MARK: - Backoff

    func testThresholdDoublesAfterEachUnhelpfulReload() {
        XCTAssertEqual(StallPolicy.reloadThreshold(buffering: false, consecutiveReloads: 0), 9)
        XCTAssertEqual(StallPolicy.reloadThreshold(buffering: false, consecutiveReloads: 1), 18)
        XCTAssertEqual(StallPolicy.reloadThreshold(buffering: false, consecutiveReloads: 2), 36)
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(
            StallPolicy.reloadThreshold(buffering: false, consecutiveReloads: 99),
            StallPolicy.maxReloadAfter)
    }

    func testBackoffSuppressesAnImmediateSecondReload() {
        // 10s frozen reloads on the first stall but not once we're one reload
        // deep — that's what stops the every-9-seconds hammering on bad signal.
        XCTAssertEqual(
            StallPolicy.action(frozen: 10, buffering: false,
                               consecutiveReloads: 1, alreadyNudged: true),
            .none)
    }

    func testNegativeReloadCountIsTreatedAsZero() {
        XCTAssertEqual(
            StallPolicy.reloadThreshold(buffering: false, consecutiveReloads: -3),
            StallPolicy.baseReloadAfter)
    }
}
