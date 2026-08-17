import XCTest
@testable import EncoreCore

/// Artist ordering in a mixed English/Chinese playlist: English names first
/// alphabetically, then Chinese names by pinyin (Charlie's rule, 2026-08-16).
final class PinyinSortTests: XCTestCase {

    private func track(_ title: String, _ artist: String) -> Track {
        Track(videoId: title, title: title, artists: [Ref(name: artist)], artistLine: artist)
    }

    func testPinyinConversion() {
        XCTAssertEqual(CJK.pinyin("陶喆"), "tao zhe")
        XCTAssertEqual(CJK.pinyin("张惠妹"), "zhang hui mei")
        XCTAssertEqual(CJK.pinyin("邓紫棋"), "deng zi qi")
        // Latin passes through untouched.
        XCTAssertEqual(CJK.pinyin("Taylor Swift"), "taylor swift")
    }

    func testEnglishNamesGroupBeforeChineseOnes() {
        let english = CJK.nameSortKey("Taylor Swift")
        let chinese = CJK.nameSortKey("陶喆")
        XCTAssertLessThan(english.0, chinese.0)
    }

    func testChineseNamesOrderByPinyinNotCodePoint() {
        // 陶喆 (t) must precede 张惠妹 (z), which is NOT their code-point order.
        let tao = CJK.nameSortKey("陶喆")
        let zhang = CJK.nameSortKey("张惠妹")
        XCTAssertTrue(tao < zhang)
        let deng = CJK.nameSortKey("邓紫棋")   // d — first of the three
        XCTAssertTrue(deng < tao)
    }

    func testFullOrderingOfAMixedList() {
        let tracks = [
            track("a", "张惠妹"),
            track("b", "Taylor Swift"),
            track("c", "陶喆"),
            track("d", "A-Lin"),
            track("e", "邓紫棋"),
        ]
        let sorted = LibrarySort.sort(tracks, by: .artist).map(\.artistLine)
        XCTAssertEqual(sorted, ["A-Lin", "Taylor Swift", "邓紫棋", "陶喆", "张惠妹"])
    }

    /// The point of sorting on the DISPLAYED name: both of these render as
    /// 陶喆, so they must sit together rather than one landing under "D".
    func testTracksOfOneArtistStayTogetherAcrossCreditVariants() {
        let tracks = [
            track("romanized", "David Tao"),
            track("zzz", "Taylor Swift"),
            track("han", "陶喆"),
        ]
        let sorted = LibrarySort.sort(tracks, by: .artist).map(\.videoId)
        let romanized = sorted.firstIndex(of: "romanized")!
        let han = sorted.firstIndex(of: "han")!
        XCTAssertEqual(abs(romanized - han), 1, "David Tao and 陶喆 should be adjacent: \(sorted)")
    }

    func testTitleBreaksTiesWithinOneArtist() {
        let tracks = [track("B side", "陶喆"), track("A side", "陶喆")]
        XCTAssertEqual(LibrarySort.sort(tracks, by: .artist).map(\.title), ["A side", "B side"])
    }
}
