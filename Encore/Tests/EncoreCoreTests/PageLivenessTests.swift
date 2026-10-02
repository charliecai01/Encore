import XCTest
@testable import EncoreCore

final class PageLivenessTests: XCTestCase {

    // MARK: - The regression that motivated this

    /// A reload that never produces `ready` must be retried. The old check was
    /// gated on playerReady, so this case retried NEVER and playback stayed
    /// broken until the app was restarted by hand.
    func testFailedReloadIsRetried() {
        XCTAssertEqual(
            PageLiveness.action(playerReady: false, sinceLastBridge: 999, sinceLastReload: 30),
            .retryFailedReload)
    }

    func testReloadStillInFlightIsLeftAlone() {
        // Well inside the timeout — a cold load legitimately takes seconds.
        XCTAssertEqual(
            PageLiveness.action(playerReady: false, sinceLastBridge: 999, sinceLastReload: 3),
            .none)
    }

    func testRetryKeepsFiringWhileItStaysBroken() {
        // Each later check should still ask for a retry, not give up.
        for elapsed in [21.0, 60.0, 3600.0] {
            XCTAssertEqual(
                PageLiveness.action(playerReady: false, sinceLastBridge: 999, sinceLastReload: elapsed),
                .retryFailedReload, "gave up after \(elapsed)s")
        }
    }

    // MARK: - The original dead-page case

    /// Silence alone only probes — a sleeping/throttled page is silent too.
    func testSilentReadyPageIsProbedNotReloaded() {
        XCTAssertEqual(
            PageLiveness.action(playerReady: true, sinceLastBridge: 20, sinceLastReload: 999),
            .probeSilentPage)
    }

    func testUnansweredProbeReloads() {
        XCTAssertEqual(
            PageLiveness.action(playerReady: true, sinceLastBridge: 40, sinceLastReload: 999,
                                probeInFlightFor: PageLiveness.probeTimeout + 1),
            .reloadDeadPage)
    }

    /// While a probe is outstanding (but not yet overdue) don't stack another
    /// one or jump to a reload.
    func testPendingProbeIsLeftAlone() {
        XCTAssertEqual(
            PageLiveness.action(playerReady: true, sinceLastBridge: 20, sinceLastReload: 999,
                                probeInFlightFor: 2),
            .none)
    }

    // MARK: - The 2026-10-02 regression: silence after sleep is not death

    /// Logged live: the Mac dark-wakes, the native 5s timer fires first, and
    /// the last bridge message is from before sleep — minutes or hours old.
    /// That used to reload a healthy paused page (and blip its audio). Any
    /// silence length must route through a probe first.
    func testLongSilenceAfterSleepStillProbesFirst() {
        for silence in [16.0, 600.0, 8 * 3600.0] {
            XCTAssertEqual(
                PageLiveness.action(playerReady: true, sinceLastBridge: silence, sinceLastReload: 999),
                .probeSilentPage, "reloaded without probing after \(silence)s of silence")
        }
    }

    func testChattyPageIsLeftAlone() {
        XCTAssertEqual(
            PageLiveness.action(playerReady: true, sinceLastBridge: 1, sinceLastReload: 999),
            .none)
    }

    /// Brief silence is normal — don't rebuild the page over a hiccup.
    func testShortSilenceIsNotDeath() {
        XCTAssertEqual(
            PageLiveness.action(playerReady: true, sinceLastBridge: PageLiveness.deadAfter - 1,
                                sinceLastReload: 999),
            .none)
    }

    /// A ready page that's chatty must never be reloaded just because its last
    /// reload was long ago — that would rebuild the page periodically forever.
    func testReadyAndHealthyIsNeverReloadedOnAge() {
        XCTAssertEqual(
            PageLiveness.action(playerReady: true, sinceLastBridge: 0, sinceLastReload: 86_400),
            .none)
    }
}
