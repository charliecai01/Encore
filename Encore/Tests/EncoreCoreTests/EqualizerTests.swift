import XCTest
@testable import EncoreCore

final class EqualizerTests: XCTestCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "EqualizerTests")!
        suite.removePersistentDomain(forName: "EqualizerTests")
        Equalizer.store = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "EqualizerTests")
        Equalizer.store = .standard
        super.tearDown()
    }

    func testDefaultsAreFlatAndDisabled() {
        let s = Equalizer.load()
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.gains, Array(repeating: 0, count: 10))
        XCTAssertEqual(s.preamp, 0)
    }

    func testEveryPresetHasTenBands() {
        for p in Equalizer.presets {
            XCTAssertEqual(p.gains.count, Equalizer.bandCount, "\(p.name) wrong band count")
        }
    }

    func testSaveLoadRoundTrip() {
        var s = EQSettings(enabled: true, preamp: -3, gains: Equalizer.preset(named: "Rock")!.gains, presetName: "Rock")
        Equalizer.save(s)
        let loaded = Equalizer.load()
        XCTAssertEqual(loaded, Equalizer.sanitized(s))
        s.enabled = false // local mutation shouldn't affect what was saved
        XCTAssertTrue(loaded.enabled)
    }

    func testSanitizeClampsOutOfRange() {
        let s = EQSettings(enabled: true, preamp: 99, gains: [99, -99, 0, 0, 0, 0, 0, 0, 0, 0])
        let c = Equalizer.sanitized(s)
        XCTAssertEqual(c.preamp, 12)
        XCTAssertEqual(c.gains[0], 12)
        XCTAssertEqual(c.gains[1], -12)
    }

    func testSanitizeFixesWrongBandCount() {
        let s = EQSettings(enabled: true, preamp: 0, gains: [1, 2, 3])
        XCTAssertEqual(Equalizer.sanitized(s).gains, Array(repeating: 0, count: 10))
    }

    func testMatchingPresetName() {
        XCTAssertEqual(Equalizer.matchingPresetName(Array(repeating: 0, count: 10)), "Flat")
        XCTAssertEqual(Equalizer.matchingPresetName(Equalizer.preset(named: "Pop")!.gains), "Pop")
        var edited = Equalizer.preset(named: "Pop")!.gains
        edited[0] += 3
        XCTAssertNil(Equalizer.matchingPresetName(edited))
    }

    func testLabels() {
        XCTAssertEqual(Equalizer.label(forBand: 0), "32")
        XCTAssertEqual(Equalizer.label(forBand: 5), "1k")
        XCTAssertEqual(Equalizer.label(forBand: 9), "16k")
    }

    func testJSPayloadShape() {
        let s = EQSettings(enabled: true, preamp: -1.5,
                           gains: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let js = Equalizer.jsPayload(s)
        XCTAssertTrue(js.contains("\"enabled\":true"))
        XCTAssertTrue(js.contains("\"preamp\":-1.50"))
        XCTAssertTrue(js.hasPrefix("{"))
        XCTAssertTrue(js.contains("\"gains\":[3.00,0.00,"))
        // Valid JSON.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(js.utf8)))
    }

    func testJSPayloadIsLocaleIndependent() {
        // A comma decimal locale must not corrupt the JSON.
        let s = EQSettings(enabled: false, preamp: 1.25, gains: Array(repeating: 2.5, count: 10))
        let js = Equalizer.jsPayload(s)
        XCTAssertTrue(js.contains("1.25"))
        XCTAssertFalse(js.contains("1,25"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(js.utf8)))
    }
}
