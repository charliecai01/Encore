import XCTest
@testable import EncoreCore

/// Siri hands the intents a loosely transcribed playlist name; these pin which
/// library playlist it resolves to (shared by both apps' App Intents).
final class VoiceCommandsTests: XCTestCase {

    private func playlist(_ title: String) -> CardItem {
        CardItem(kind: .playlist, title: title, playlistId: "PL" + title)
    }

    private var library: [CardItem] {
        ["R&B by Sonnet", "Fav Songs", "Road Trip", "Road Trip 2019", "周杰伦 精选", "Café Jazz"].map(playlist)
    }

    func testFavoritesUnderEitherSpelling() {
        XCTAssertEqual(VoiceCommands.favoritesPlaylist(in: library)?.title, "Fav Songs")
        let old = [playlist("Road Trip"), playlist("Favorite Songs")]
        XCTAssertEqual(VoiceCommands.favoritesPlaylist(in: old)?.title, "Favorite Songs")
        XCTAssertNil(VoiceCommands.favoritesPlaylist(in: [playlist("Road Trip")]))
    }

    func testExactBeatsPrefix() {
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "road trip", in: library)?.title, "Road Trip")
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "Road trip 2019", in: library)?.title, "Road Trip 2019")
    }

    func testSpokenAmpersandAndFiller() {
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "R and B by sonnet", in: library)?.title, "R&B by Sonnet")
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "my road trip playlist", in: library)?.title, "Road Trip")
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "sonnet", in: library)?.title, "R&B by Sonnet")
    }

    func testAccentsAndTraditionalChinese() {
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "cafe jazz", in: library)?.title, "Café Jazz")
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "周杰倫", in: library)?.title, "周杰伦 精选")
    }

    /// "play R&B in Encore" — Siri needs "R&B" registered as a synonym of
    /// "R&B by Sonnet" or the request never reaches the intent.
    func testSpokenAliases() {
        let aliases = VoiceCommands.spokenAliases(for: library)
        XCTAssertEqual(aliases["PLR&B by Sonnet"], ["R&B", "R and B by Sonnet", "R and B"])
        XCTAssertNil(aliases["PLRoad Trip"])
        XCTAssertNil(aliases["PLFav Songs"])
    }

    func testAliasNeverShadowsAnotherPlaylist() {
        // "Chill - Morning" must not claim "Chill", which is its own playlist;
        // two "Jazz by …" playlists can't both own "Jazz".
        let lib = ["Chill", "Chill - Morning", "Jazz by Ann", "Jazz by Bob"].map(playlist)
        let aliases = VoiceCommands.spokenAliases(for: lib)
        XCTAssertNil(aliases["PLChill - Morning"])
        XCTAssertNil(aliases["PLJazz by Ann"])
        XCTAssertNil(aliases["PLJazz by Bob"])
    }

    func testWordOverlapFallbackAndNoMatch() {
        XCTAssertEqual(VoiceCommands.bestPlaylistMatch(for: "jazz from the cafe", in: library)?.title, "Café Jazz")
        XCTAssertNil(VoiceCommands.bestPlaylistMatch(for: "heavy metal", in: library))
        XCTAssertNil(VoiceCommands.bestPlaylistMatch(for: "the playlist", in: library))
    }
}
