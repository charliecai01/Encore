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

    /// Same words, different order — the listing reads "孫燕姿 - Yanzi Sun"
    /// while the credit says "Sun Yanzi".
    func testWordOrderDifferenceStillMatches() {
        XCTAssertEqual(NativeNames.resolve(entityTitle: "孫燕姿 - Yanzi Sun", query: "Sun Yanzi"),
                       "孙燕姿")
    }

    // MARK: - The curated map (Resources/artist-names.json)

    /// The map is the authoritative source; if it fails to load, every CJK
    /// artist silently falls back to romanized, so assert it's really there.
    func testCuratedMapLoads() {
        XCTAssertFalse(NativeNames.displayOverrides.isEmpty,
                       "artist-names.json didn't load — check the SwiftPM resource")
    }

    /// YouTube credits one artist under several names; all must land on the
    /// same display name.
    func testAllVariantsOfOneArtistAgree() {
        for variant in ["A Mei", "aMEI", "Chang Hui Mei"] {
            XCTAssertEqual(NativeNames.overrideName(for: variant), "张惠妹", "failed for \(variant)")
        }
        for variant in ["G.E.M.", "G.E.M. 鄧紫棋", "G.E.M.鄧紫棋"] {
            XCTAssertEqual(NativeNames.overrideName(for: variant), "邓紫棋", "failed for \(variant)")
        }
        for variant in ["Leehom Wang", "Wang Leehom"] {
            XCTAssertEqual(NativeNames.overrideName(for: variant), "王力宏", "failed for \(variant)")
        }
    }

    /// The names Charlie confirmed by hand.
    func testConfirmedNames() {
        XCTAssertEqual(NativeNames.overrideName(for: "JJ Lin"), "林俊杰")
        XCTAssertEqual(NativeNames.overrideName(for: "Shan Yi Chun"), "单依纯")
        XCTAssertEqual(NativeNames.overrideName(for: "Eric Chou"), "周兴哲")
        XCTAssertEqual(NativeNames.overrideName(for: "Sun Yanzi"), "孙燕姿")
    }

    /// A-Lin is billed romanized from either direction.
    func testALinFromEitherScript() {
        XCTAssertEqual(NativeNames.overrideName(for: "A-Lin"), "A-Lin")
        XCTAssertEqual(NativeNames.overrideName(for: "黄丽玲"), "A-Lin")
        XCTAssertEqual(NativeNames.overrideName(for: "黃麗玲"), "A-Lin")
    }

    /// A mixed-script credit must not claim the bare Latin word: the library
    /// credits "Mike 曾比特", and indexing that under "mike" renamed every
    /// unrelated artist called Mike.
    func testMixedScriptEntryDoesNotClaimTheBareLatinName() {
        XCTAssertNil(NativeNames.overrideName(for: "Mike"))
        // The full credit still resolves.
        XCTAssertEqual(NativeNames.overrideName(for: "Mike 曾比特"), "曾比特")
    }

    func testWesternArtistsAreNotInTheMap() {
        XCTAssertNil(NativeNames.overrideName(for: "Taylor Swift"))
        XCTAssertNil(NativeNames.overrideName(for: "Olivia Dean"))
        XCTAssertNil(NativeNames.overrideName(for: "Drake"))
    }

    // MARK: - Mixed-script names

    /// "G.E.M. 鄧紫棋" should read 邓紫棋, "JJ 林俊傑" should read 林俊杰 — once
    /// the real name is there the stage prefix is noise.
    func testMixedScriptNamesShowOnlyTheHanPart() {
        XCTAssertEqual(NativeNames.hanRun(in: "G.E.M. 鄧紫棋"), "邓紫棋")
        XCTAssertEqual(NativeNames.hanRun(in: "G.E.M.鄧紫棋"), "邓紫棋")
        XCTAssertEqual(NativeNames.hanRun(in: "JJ 林俊傑"), "林俊杰")
        XCTAssertEqual(NativeNames.hanRun(in: "JJ林俊傑"), "林俊杰")
    }

    func testAllHanNameIsJustNormalized() {
        XCTAssertEqual(NativeNames.hanRun(in: "周興哲"), "周兴哲")
        XCTAssertEqual(NativeNames.hanRun(in: "單依純"), "单依纯")
    }

    func testNameWithNoHanHasNoHanRun() {
        XCTAssertNil(NativeNames.hanRun(in: "Taylor Swift"))
    }

    /// The longest run wins, so a stray character can't beat the real name.
    func testLongestHanRunWins() {
        XCTAssertEqual(NativeNames.hanRun(in: "A 王 feat. 鄧紫棋"), "邓紫棋")
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

    /// DESCRIPTIVE parentheticals go — they say nothing about the recording.
    func testDescriptiveParentheticalsAreStripped() {
        XCTAssertEqual(NativeNames.displayTitle("天若有情 (電視劇「錦繡未央」片尾曲)"), "天若有情")
    }

    /// VERSION markers stay, so a different recording stays tellable apart —
    /// otherwise a live cut and its studio original render identically.
    func testVersionMarkersAreKept() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外 (G.E.M.重生版)"), "光年之外 (G.E.M.重生版)")
        XCTAssertEqual(NativeNames.displayTitle("Where Did U Go (G.E.M.重生版)"),
                       "Where Did U Go (G.E.M.重生版)")
        XCTAssertEqual(NativeNames.displayTitle("All Too Well (10 Minute Version)"),
                       "All Too Well (10 Minute Version)")
        XCTAssertEqual(NativeNames.displayTitle("First Of May (Live)"), "First Of May (Live)")
    }

    /// Nested brackets inside the group must not end the scan early.
    func testNestedBracketsInsideTheGroup() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外 (電影《Passengers》主題曲)"), "光年之外")
    }

    /// A descriptive group goes while a version marker beside it survives.
    func testMixedGroupsKeepOnlyTheVersion() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外 (電影主題曲) (Live)"), "光年之外 (Live)")
        XCTAssertEqual(NativeNames.displayTitle("Song [Remastered] (Live)"), "Song [Remastered] (Live)")
    }

    func testFullWidthParenthesesAreHandled() {
        XCTAssertEqual(NativeNames.displayTitle("光年之外（重生版）"), "光年之外（重生版）")
        XCTAssertEqual(NativeNames.displayTitle("天若有情（片尾曲）"), "天若有情")
    }

    /// A title that is ONLY a parenthetical must survive rather than vanish.
    func testATitleIsNeverStrippedToNothing() {
        XCTAssertEqual(NativeNames.displayTitle("(Interlude)"), "(Interlude)")
    }

    /// Both rules together: translation split first, then the parenthetical.
    func testTranslationAndParentheticalTogether() {
        XCTAssertEqual(NativeNames.displayTitle("我恨我愛你 - Hate to Love You (Live)"), "我恨我爱你 (Live)")
    }

    // MARK: - Real titles from Charlie's Favorite Songs

    /// The parenthetical sits in the MIDDLE of the raw string and only
    /// becomes trailing once the English half is split off — the scan has to
    /// run again after the split, or it survives on screen.
    func testDescriptiveParentheticalExposedByTheSplitIsStripped() {
        let raw = "有一種悲傷 (電影《比悲傷更悲傷的故事》主題曲) - A Kind of Sorrow (The movie theme song of \"More than Blue\")"
        XCTAssertEqual(NativeNames.displayTitle(raw), "有一种悲伤")
    }

    /// A dash-suffixed version marker is a different recording and must
    /// survive, or it collapses onto the studio cut in the list.
    func testDashSuffixedVersionMarkerSurvivesTheSplit() {
        let raw = "有一種悲傷 - From THE FIRST TAKE - A Kind of Sorrow - From THE FIRST TAKE"
        XCTAssertEqual(NativeNames.displayTitle(raw), "有一种悲伤 - From THE FIRST TAKE")
    }

    /// The two above must not end up reading the same.
    func testTheTwoRecordingsStayDistinct() {
        let studio = NativeNames.displayTitle("有一種悲傷 (電影《比悲傷更悲傷的故事》主題曲) - A Kind of Sorrow")
        let live = NativeNames.displayTitle("有一種悲傷 - From THE FIRST TAKE - A Kind of Sorrow")
        XCTAssertNotEqual(studio, live)
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
