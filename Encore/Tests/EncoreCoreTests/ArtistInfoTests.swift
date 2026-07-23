import XCTest
@testable import EncoreCore

final class ArtistInfoTests: XCTestCase {
    // Fixed "now" so age math is deterministic: 2026-07-22 UTC.
    private var now: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 22
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    func testCandidatesSplitCombinedNames() {
        XCTAssertEqual(ArtistInfo.candidates(from: "陶喆 - David Tao"),
                       ["陶喆", "David Tao", "陶喆 - David Tao"])
        XCTAssertEqual(ArtistInfo.candidates(from: "Radiohead"), ["Radiohead"])
    }

    func testParseTime() {
        XCTAssertEqual(ArtistInfo.parseTime("+1969-07-11T00:00:00Z")?.year, 1969)
        XCTAssertEqual(ArtistInfo.parseTime("+1969-07-11T00:00:00Z")?.month, 7)
        XCTAssertEqual(ArtistInfo.parseTime("+1969-07-11T00:00:00Z")?.day, 11)
        // Year-precision values pad month/day with 00 — must come back nil.
        let yearOnly = ArtistInfo.parseTime("+1993-00-00T00:00:00Z")
        XCTAssertEqual(yearOnly?.year, 1993)
        XCTAssertNil(yearOnly?.month)
        XCTAssertNil(yearOnly?.day)
        XCTAssertNil(ArtistInfo.parseTime("garbage"))
    }

    func testAgeAroundBirthday() {
        // Birthday already passed this year (July 11 vs now July 22).
        XCTAssertEqual(ArtistInfo.age(year: 1969, month: 7, day: 11, now: now), 57)
        // Birthday later this year.
        XCTAssertEqual(ArtistInfo.age(year: 1969, month: 12, day: 1, now: now), 56)
        // Year-only precision.
        XCTAssertEqual(ArtistInfo.age(year: 1969, month: nil, day: nil, now: now), 57)
        XCTAssertNil(ArtistInfo.age(year: 1600, month: nil, day: nil, now: now))
    }

    func testComposePersonAllFactsUsesRecordedPronoun() {
        var f = ArtistFacts()
        f.gender = .male
        f.birthplace = "Hong Kong"
        f.birthYear = 1969; f.birthMonth = 7; f.birthDay = 11
        f.country = "Taiwan"
        f.careerStartYear = 1993
        let s = ArtistInfo.compose(name: "David Tao", facts: f, now: now)
        XCTAssertEqual(s, "David Tao was born in Hong Kong, Taiwan. "
                        + "He is 57 years old, born July 11, 1969. "
                        + "He is most active in Taiwan. "
                        + "He first entered the scene in 1993.")
    }

    func testComposeFemalePronoun() {
        var f = ArtistFacts()
        f.gender = .female
        f.birthYear = 1972
        let s = ArtistInfo.compose(name: "A-Mei", facts: f, now: now)!
        XCTAssertTrue(s.contains("She is about 54 years old"))
    }

    func testComposeUnrecordedGenderFallsBackToThey() {
        var f = ArtistFacts()
        f.birthYear = 1969
        f.country = "Taiwan"
        let s = ArtistInfo.compose(name: "X", facts: f, now: now)!
        XCTAssertTrue(s.contains("They are about 57 years old"))
        XCTAssertTrue(s.contains("They are most active in Taiwan."))
    }

    func testComposeSkipsMissingFacts() {
        var f = ArtistFacts()
        f.country = "Japan"
        XCTAssertEqual(ArtistInfo.compose(name: "X", facts: f, now: now),
                       "They are most active in Japan.")
        XCTAssertNil(ArtistInfo.compose(name: "X", facts: ArtistFacts(), now: now))
    }

    func testComposeDeceased() {
        var f = ArtistFacts()
        f.gender = .male
        f.birthYear = 1958
        f.deathYear = 2009
        f.country = "United States"
        let s = ArtistInfo.compose(name: "Y", facts: f, now: now)
        XCTAssertTrue(s!.contains("He passed away in 2009, at around 51 years old"))
        XCTAssertTrue(s!.contains("He was most active in United States."))
    }

    func testComposeAppendsWikipediaKnownFor() {
        var f = ArtistFacts()
        f.gender = .male
        f.birthYear = 1969
        f.knownFor = ["David Tao is a Taiwanese singer-songwriter.",
                      "He is credited with pioneering Mandopop R&B."]
        let s = ArtistInfo.compose(name: "David Tao", facts: f, now: now)!
        XCTAssertTrue(s.hasSuffix("David Tao is a Taiwanese singer-songwriter. "
                                  + "He is credited with pioneering Mandopop R&B."))
    }

    func testComposeKnownForFallbackFromOccupationsAndGenres() {
        var f = ArtistFacts()
        f.gender = .female
        f.birthYear = 1972
        f.occupations = ["singer", "record producer"]
        f.genres = ["Mandopop", "rhythm and blues"]
        let s = ArtistInfo.compose(name: "Z", facts: f, now: now)!
        XCTAssertTrue(s.contains("She is best known as a singer and record producer."))
        XCTAssertTrue(s.contains("Her music spans Mandopop and rhythm and blues."))
    }

    func testKnownForSentencesStripParentheticalsAndSplit() {
        let extract = "Tao Zhe (born July 11, 1969), known as David Tao, is a Taiwanese singer. "
            + "He is known for fusing R&B with rock. His third sentence should be dropped."
        let out = ArtistInfo.knownForSentences(from: extract, limit: 2)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], "Tao Zhe, known as David Tao, is a Taiwanese singer.")
        XCTAssertEqual(out[1], "He is known for fusing R&B with rock.")
        XCTAssertFalse(out.joined().contains("born July"))
    }

    func testKnownForSentencesProtectsInitials() {
        let out = ArtistInfo.knownForSentences(from: "R. Kelly is a singer. Second sentence here.",
                                               limit: 2)
        XCTAssertEqual(out[0], "R. Kelly is a singer.")
        XCTAssertEqual(out[1], "Second sentence here.")
    }

    func testComposeBandWithMembers() {
        var f = ArtistFacts()
        f.isBand = true
        f.birthplace = "Abingdon"
        f.birthYear = 1985
        f.country = "United Kingdom"
        f.careerStartYear = 1985 // same as formation — the career sentence must not repeat
        f.members = [
            BandMember(name: "Thom Yorke", role: "vocals"),
            BandMember(name: "Jonny Greenwood", role: "guitar"),
            BandMember(name: "Colin Greenwood", role: "bass"),
        ]
        let s = ArtistInfo.compose(name: "Radiohead", facts: f, now: now)!
        XCTAssertTrue(s.hasPrefix("Radiohead was formed in Abingdon, United Kingdom."))
        XCTAssertTrue(s.contains("The band is 41 years old, formed in 1985."))
        XCTAssertFalse(s.contains("entered the scene"), "duplicate formation year must be skipped")
        XCTAssertTrue(s.hasSuffix("The members are Thom Yorke (vocals), Jonny Greenwood (guitar), and Colin Greenwood (bass)."))
    }

    func testComposeBandCareerKeptWhenDistinct() {
        var f = ArtistFacts()
        f.isBand = true
        f.birthYear = 1985
        f.careerStartYear = 1992
        f.members = [BandMember(name: "A"), BandMember(name: "B")]
        let s = ArtistInfo.compose(name: "Z", facts: f, now: now)!
        XCTAssertTrue(s.contains("They first entered the scene in 1992."))
        XCTAssertTrue(s.contains("The members are A and B."))
    }

    func testJoinedGrammar() {
        XCTAssertEqual(ArtistInfo.joined(["A"]), "A")
        XCTAssertEqual(ArtistInfo.joined(["A", "B"]), "A and B")
        XCTAssertEqual(ArtistInfo.joined(["A", "B", "C"]), "A, B, and C")
    }

    func testPrettyRole() {
        XCTAssertEqual(ArtistInfo.prettyRole("voice"), "vocals")
        XCTAssertEqual(ArtistInfo.prettyRole("bass guitar"), "bass")
        XCTAssertEqual(ArtistInfo.prettyRole("Electric Guitar"), "guitar")
        XCTAssertEqual(ArtistInfo.prettyRole("Singer"), "singer")
    }

    /// Live resolution end-to-end (skips offline / if Wikidata is unreachable).
    func testLiveResolveKnownArtist() async throws {
        if ProcessInfo.processInfo.environment["ENCORE_SKIP_LIVE"] == "1" {
            throw XCTSkip("ENCORE_SKIP_LIVE set")
        }
        guard let s = await ArtistInfo.summary(forName: "陶喆 - David Tao", now: now) else {
            throw XCTSkip("Wikidata unreachable or entity unresolved")
        }
        XCTAssertTrue(s.contains("born"), "summary lacks a birth sentence: \(s)")
        XCTAssertTrue(s.contains("Hong Kong"), "unexpected birthplace: \(s)")
        XCTAssertTrue(s.contains("He "), "Wikidata records male for David Tao; got: \(s)")
        XCTAssertTrue(s.lowercased().contains("singer"), "no known-for content: \(s)")
    }
}
