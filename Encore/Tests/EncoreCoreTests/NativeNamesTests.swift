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

    // MARK: - Pinned display names

    /// A-Lin is billed romanized everywhere, so 黄丽玲 reads wrong.
    func testALinStaysRomanizedFromEitherDirection() {
        XCTAssertEqual(NativeNames.resolve(entityTitle: "黃麗玲 - A-Lin+", query: "A-Lin"), "A-Lin")
        XCTAssertEqual(NativeNames.overrideName(for: "A-Lin"), "A-Lin")
        XCTAssertEqual(NativeNames.overrideName(for: "黄丽玲"), "A-Lin")
        // Traditional spelling folds to the same override.
        XCTAssertEqual(NativeNames.overrideName(for: "黃麗玲"), "A-Lin")
    }

    func testOtherArtistsAreUnaffectedByTheOverrideList() {
        XCTAssertNil(NativeNames.overrideName(for: "Jacky Cheung"))
        XCTAssertNil(NativeNames.overrideName(for: "张学友"))
    }

    // MARK: - Song titles

    func testTranslatedHalfIsStrippedFromTitles() {
        XCTAssertEqual(NativeNames.displayTitle("我恨我愛你 - Hate to Love You"), "我恨我爱你")
        XCTAssertEqual(NativeNames.displayTitle("永遠的畫面 - Forever Pictures"), "永远的画面")
        XCTAssertEqual(NativeNames.displayTitle("真實 - Reality"), "真实")
    }

    /// Titles are normalized to Simplified, matching the artist names.
    func testTitleIsConvertedToSimplified() {
        XCTAssertEqual(NativeNames.displayTitle("記得 - Remember"), "记得")
        XCTAssertEqual(NativeNames.displayTitle("聽海"), "听海")
    }

    func testTitlesWithoutATranslatedHalfAreUntouched() {
        XCTAssertEqual(NativeNames.displayTitle("P.S.我愛你"), "P.S.我爱你")
        XCTAssertEqual(NativeNames.displayTitle("以前，以後"), "以前，以后")
        XCTAssertEqual(NativeNames.displayTitle("Hate to Love You"), "Hate to Love You")
        XCTAssertEqual(NativeNames.displayTitle("Blank Space"), "Blank Space")
    }

    // MARK: - Trailing parentheticals

    func testTrailingParentheticalsAreStripped() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外 (G.E.M.重生版)"), "光年之外")
        XCTAssertEqual(NativeNames.displayTitle("天若有情 (電視劇「錦繡未央」片尾曲)"), "天若有情")
        // An English title with no Han must be cleaned up too.
        XCTAssertEqual(NativeNames.displayTitle("Where Did U Go (G.E.M.重生版)"), "Where Did U Go")
        XCTAssertEqual(NativeNames.displayTitle("All Too Well (10 Minute Version)"), "All Too Well")
    }

    /// Nested brackets inside the group must not end the scan early.
    func testNestedBracketsInsideTheGroup() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外 (電影《Passengers》主題曲)"), "光年之外")
    }

    func testMultipleTrailingGroupsAllGo() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外 (電影主題曲) (Live)"), "光年之外")
        XCTAssertEqual(NativeNames.displayTitle("Song [Remastered] (Live)"), "Song")
    }

    func testFullWidthParenthesesAreHandled() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外（重生版）"), "光年之外")
    }

    /// A title that is ONLY a parenthetical must survive rather than vanish.
    func testATitleIsNeverStrippedToNothing() {
        XCTAssertEqual(NativeNames.displayTitle("(Interlude)"), "(Interlude)")
    }

    /// Both rules together: translation split first, then the parenthetical.
    func testTranslationAndParentheticalTogether() {
        XCTAssertEqual(NativeNames.displayTitle("我恨我愛你 - Hate to Love You (Live)"), "我恨我爱你")
    }

    /// An English title that happens to contain a dash must not lose half.
    func testEnglishTitleWithADashSurvives() {
        XCTAssertEqual(NativeNames.displayTitle("Hate to Love You - Live"),
                       "Hate to Love You - Live")
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
