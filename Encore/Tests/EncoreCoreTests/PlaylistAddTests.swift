import XCTest
@testable import EncoreCore

final class PlaylistAddTests: XCTestCase {

    private func track(_ id: String, _ title: String, _ artist: String) -> Track {
        Track(videoId: id, title: title, artists: [Ref(name: artist)], artistLine: artist)
    }

    func testASongAlreadyInThePlaylistIsNotAddedAgain() {
        let existing = [track("a1", "真實 - Reality", "A Mei")]
        let split = PlaylistAdd.split([track("a1", "真實 - Reality", "A Mei")], existing: existing)
        XCTAssertTrue(split.toAdd.isEmpty)
        XCTAssertEqual(split.duplicates.count, 1)
    }

    func testNewSongsPassThrough() {
        let existing = [track("a1", "真實", "A Mei")]
        let split = PlaylistAdd.split([track("b2", "記得", "A Mei")], existing: existing)
        XCTAssertEqual(split.toAdd.map(\.videoId), ["b2"])
        XCTAssertTrue(split.duplicates.isEmpty)
    }

    /// A plain re-upload displays identically in this app, so adding it would
    /// look like an exact duplicate row.
    func testSameSongUnderADifferentVideoIdCountsAsADuplicate() {
        let existing = [track("a1", "光年之外", "G.E.M.")]
        let split = PlaylistAdd.split([track("zzz", "光年之外", "G.E.M.")], existing: existing)
        XCTAssertTrue(split.toAdd.isEmpty)
        XCTAssertEqual(split.duplicates.count, 1)
    }

    /// But a DIFFERENT RECORDING is a different song and must stay addable —
    /// the version marker survives into the display title, so the identities
    /// differ (Charlie's call: "so i know they are diff").
    func testAVersionOfATrackIsNotADuplicate() {
        let existing = [track("a1", "光年之外", "G.E.M.")]
        let split = PlaylistAdd.split([track("zzz", "光年之外 (G.E.M.重生版)", "G.E.M.")],
                                      existing: existing)
        XCTAssertEqual(split.toAdd.count, 1)
        XCTAssertTrue(split.duplicates.isEmpty)

        let live = PlaylistAdd.split([track("b2", "First Of May (Live)", "Jacky Cheung")],
                                     existing: [track("a2", "First Of May", "Jacky Cheung")])
        XCTAssertEqual(live.toAdd.count, 1)
    }

    /// Traditional vs Simplified is the same song too.
    func testScriptDifferenceStillCountsAsADuplicate() {
        let existing = [track("a1", "記得", "A Mei")]
        let split = PlaylistAdd.split([track("b2", "记得", "A Mei")], existing: existing)
        XCTAssertTrue(split.toAdd.isEmpty)
    }

    func testRepeatsWithinTheBatchAreCollapsed() {
        let split = PlaylistAdd.split([track("a1", "X", "Y"), track("a1", "X", "Y")], existing: [])
        XCTAssertEqual(split.toAdd.count, 1)
        XCTAssertEqual(split.duplicates.count, 1)
    }

    func testDifferentArtistsWithTheSameTitleAreNotDuplicates() {
        let existing = [track("a1", "Hold On", "En Vogue")]
        let split = PlaylistAdd.split([track("b2", "Hold On", "Justin Bieber")], existing: existing)
        XCTAssertEqual(split.toAdd.count, 1)
    }

    // MARK: - Messages

    func testMessageForAnAllDuplicateAdd() {
        XCTAssertEqual(PlaylistAdd.resultMessage(added: 0, duplicates: 1, failed: 0,
                                                 playlistTitle: "Favorite Songs"),
                       "Already in Favorite Songs")
        XCTAssertEqual(PlaylistAdd.resultMessage(added: 0, duplicates: 3, failed: 0,
                                                 playlistTitle: "Favorite Songs"),
                       "All 3 are already in Favorite Songs")
    }

    func testMessageForAPartialAdd() {
        XCTAssertEqual(PlaylistAdd.resultMessage(added: 2, duplicates: 1, failed: 0,
                                                 playlistTitle: "R&B"),
                       "Added 2 to R&B · 1 already there")
    }

    func testMessageWhenEverythingFailed() {
        XCTAssertEqual(PlaylistAdd.resultMessage(added: 0, duplicates: 0, failed: 0,
                                                 playlistTitle: "R&B"),
                       "Couldn't add — you can only edit your own playlists")
    }
}
