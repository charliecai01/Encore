import XCTest
@testable import EncoreCore

final class EpisodeProgressTests: XCTestCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "EpisodeProgressTests")!
        suite.removePersistentDomain(forName: "EpisodeProgressTests")
        EpisodeProgress.store = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "EpisodeProgressTests")
        EpisodeProgress.store = .standard
        super.tearDown()
    }

    func testSaveAndReadBack() {
        EpisodeProgress.save("ep1", position: 120, duration: 3600)
        let e = EpisodeProgress.entry(for: "ep1")
        XCTAssertEqual(e?.position, 120)
        XCTAssertEqual(e?.duration, 3600)
    }

    func testTinyPositionsAreIgnored() {
        EpisodeProgress.save("ep1", position: 3, duration: 3600)
        XCTAssertNil(EpisodeProgress.entry(for: "ep1"))
        EpisodeProgress.save("", position: 100, duration: 3600)
        XCTAssertTrue(EpisodeProgress.all().isEmpty)
    }

    func testResumeRewindsFiveSeconds() {
        EpisodeProgress.save("ep1", position: 600, duration: 3600)
        XCTAssertEqual(EpisodeProgress.resumePosition(for: "ep1"), 595)
    }

    func testNoResumeWhenBarelyStarted() {
        EpisodeProgress.save("ep1", position: 12, duration: 3600)
        XCTAssertNil(EpisodeProgress.resumePosition(for: "ep1"))
    }

    func testNoResumeWhenEffectivelyFinished() {
        EpisodeProgress.save("ep1", position: 3590, duration: 3600)
        XCTAssertNil(EpisodeProgress.resumePosition(for: "ep1"))
    }

    func testResumeWithUnknownDurationStillWorks() {
        EpisodeProgress.save("ep1", position: 600, duration: 0)
        XCTAssertEqual(EpisodeProgress.resumePosition(for: "ep1"), 595)
    }

    func testFractionAndRemaining() {
        EpisodeProgress.save("ep1", position: 900, duration: 3600)
        XCTAssertEqual(EpisodeProgress.fraction(for: "ep1")!, 0.25, accuracy: 0.001)
        XCTAssertEqual(EpisodeProgress.remainingSeconds(for: "ep1")!, 2700, accuracy: 0.001)
        XCTAssertNil(EpisodeProgress.fraction(for: "missing"))
    }

    func testClearRemovesEntry() {
        EpisodeProgress.save("ep1", position: 600, duration: 3600)
        EpisodeProgress.clear("ep1")
        XCTAssertNil(EpisodeProgress.entry(for: "ep1"))
    }

    func testPruningKeepsNewest() {
        for i in 0..<(EpisodeProgress.maxEntries + 20) {
            EpisodeProgress.save("ep\(i)", position: 100, duration: 200)
        }
        let map = EpisodeProgress.all()
        XCTAssertEqual(map.count, EpisodeProgress.maxEntries)
    }
}
