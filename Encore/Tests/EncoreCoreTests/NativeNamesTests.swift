import XCTest
@testable import EncoreCore

/// Native-name resolution for CJK artists. The entity titles below are the
/// real strings YouTube returned for these artists on 2026-08-14.
final class NativeNamesTests: XCTestCase {

    func testJackyCheungResolvesToSimplified() {
        // YouTube lists him Traditional; Charlie wants Simplified.
        XCTAssertEqual(NativeNames.resolve(entityTitle: "張學友 - Jacky Cheung",
                                           query: "Jacky Cheung"), "张学友")
    }

    func testAMeiResolvesDespitePunctuationAndCasing() {
        // Query "A-Mei" vs entity's "aMEI" — hyphen and case must not matter.
        XCTAssertEqual(NativeNames.resolve(entityTitle: "張惠妹 - aMEI",
                                           query: "A-Mei"), "张惠妹")
    }

    func testEnglishArtistGetsNoNativeName() {
        XCTAssertNil(NativeNames.resolve(entityTitle: "Taylor Swift", query: "Taylor Swift"))
        XCTAssertNil(NativeNames.resolve(entityTitle: "Olivia Dean", query: "Olivia Dean"))
    }

    /// The guard that stops one artist being relabelled with another's name.
    func testMismatchedArtistIsRejected() {
        XCTAssertNil(NativeNames.resolve(entityTitle: "張學友 - Jacky Cheung",
                                         query: "Jay Chou"))
        XCTAssertNil(NativeNames.resolve(entityTitle: "周杰倫 - Jay Chou",
                                         query: "Jacky Cheung"))
    }

    /// A native-only entity can't be verified against a romanized query, so
    /// it must not be trusted — that's how a wrong name would sneak in.
    func testNativeOnlyEntityIsNotTrustedForARomanizedQuery() {
        XCTAssertNil(NativeNames.resolve(entityTitle: "周杰倫", query: "Jacky Cheung"))
    }

    func testHanQueryIsNormalizedToSimplified() {
        XCTAssertEqual(NativeNames.resolve(entityTitle: "周杰倫", query: "周杰倫"), "周杰伦")
        // Simplified query against a Traditional listing still matches.
        XCTAssertEqual(NativeNames.resolve(entityTitle: "周杰倫", query: "周杰伦"), "周杰伦")
    }

    // MARK: - Parsing pieces

    func testNativePartHandlesSeveralSeparators() {
        XCTAssertEqual(NativeNames.nativePart(of: "張學友 - Jacky Cheung"), "张学友")
        XCTAssertEqual(NativeNames.nativePart(of: "陶喆 – David Tao"), "陶喆")
        XCTAssertEqual(NativeNames.nativePart(of: "李榮浩"), "李荣浩")
        XCTAssertNil(NativeNames.nativePart(of: "Bruno Mars"))
    }

    func testLatinPartExtraction() {
        XCTAssertEqual(NativeNames.latinPart(of: "張學友 - Jacky Cheung"), "Jacky Cheung")
        XCTAssertNil(NativeNames.latinPart(of: "周杰倫"))
    }

    func testLatinKeyIgnoresCaseAndPunctuation() {
        XCTAssertEqual(NativeNames.latinKey("A-Mei"), "amei")
        XCTAssertEqual(NativeNames.latinKey("aMEI"), "amei")
        XCTAssertEqual(NativeNames.latinKey("Jacky Cheung"), "jackycheung")
        XCTAssertEqual(NativeNames.latinKey("張學友"), "")
    }
}
