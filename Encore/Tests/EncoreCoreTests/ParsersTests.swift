import XCTest
@testable import EncoreCore

/// Parsers.swift has no offline unit coverage otherwise — everything else
/// exercising it goes through the live/auth-gated suites, which auto-skip
/// when there's no network. These fixtures give the core parse paths a fast,
/// deterministic check.
final class ParsersTests: XCTestCase {

    // MARK: - artistsAlbumAndLine

    func testArtistsAlbumAndLineJoinsArtistRefs() {
        let runsJSON = """
        [
          { "text": "Artist One", "navigationEndpoint": { "browseEndpoint": { "browseId": "UC111" } } },
          { "text": " & " },
          { "text": "Artist Two", "navigationEndpoint": { "browseEndpoint": { "browseId": "UC222" } } }
        ]
        """
        let runs = JSONValue.parse(Data(runsJSON.utf8)).array ?? []
        let (artists, album, line) = P.artistsAlbumAndLine(
            fromRuns: runs, fallbackText: "unused", stripLabelsAndDuration: false)
        XCTAssertEqual(artists.map(\.name), ["Artist One", "Artist Two"])
        XCTAssertNil(album)
        XCTAssertEqual(line, "Artist One, Artist Two")
    }

    func testArtistsAlbumAndLineStripsLabelsAndDurationInFallback() {
        // No artist refs in the runs -> falls back to splitting the flex-column
        // subtitle text, dropping the "Song" label and the trailing duration.
        let line = P.artistsAlbumAndLine(
            fromRuns: [], fallbackText: "Song • Some Artist • 3:21", stripLabelsAndDuration: true).line
        XCTAssertEqual(line, "Some Artist")
    }

    func testArtistsAlbumAndLineQueueFallbackTakesFirstPiece() {
        // Queue rows use the simpler fallback: no label/duration filtering.
        let line = P.artistsAlbumAndLine(
            fromRuns: [], fallbackText: "Some Artist • Some Album", stripLabelsAndDuration: false).line
        XCTAssertEqual(line, "Some Artist")
    }

    // MARK: - track(fromMRLIR:)

    func testTrackFromMRLIRParsesArtistAlbumAndDuration() {
        let json = """
        {
          "playlistItemData": { "videoId": "vid123" },
          "flexColumns": [
            { "musicResponsiveListItemFlexColumnRenderer": { "text": { "runs": [{ "text": "My Song" }] } } },
            { "musicResponsiveListItemFlexColumnRenderer": { "text": { "runs": [
              { "text": "My Artist", "navigationEndpoint": { "browseEndpoint": { "browseId": "UC999" } } },
              { "text": " • " },
              { "text": "3:21" }
            ] } } }
          ]
        }
        """
        let track = P.track(fromMRLIR: JSONValue.parse(Data(json.utf8)))
        XCTAssertEqual(track?.videoId, "vid123")
        XCTAssertEqual(track?.title, "My Song")
        XCTAssertEqual(track?.artistLine, "My Artist")
        XCTAssertEqual(track?.durationSeconds, 201)
    }

    func testTrackFromMRLIRReturnsNilWithoutVideoId() {
        let json = """
        { "flexColumns": [] }
        """
        XCTAssertNil(P.track(fromMRLIR: JSONValue.parse(Data(json.utf8))))
    }

    // MARK: - card(fromMTRIR:)

    func testCardFromMTRIRStripsPlaylistVLPrefix() {
        let json = """
        {
          "title": { "runs": [{ "text": "My Playlist" }] },
          "subtitle": { "runs": [{ "text": "50 tracks" }] },
          "navigationEndpoint": { "browseEndpoint": { "browseId": "VLPLabc123", "pageType": "MUSIC_PAGE_TYPE_PLAYLIST" } }
        }
        """
        let card = P.card(fromMTRIR: JSONValue.parse(Data(json.utf8)))
        XCTAssertEqual(card?.kind, .playlist)
        XCTAssertEqual(card?.browseId, "VLPLabc123")
        XCTAssertEqual(card?.playlistId, "PLabc123")
    }

    // MARK: - queueResult

    func testQueueResultParsesTracksAndCurrentIndex() {
        let json = """
        {
          "playlistPanelRenderer": {
            "contents": [
              {
                "playlistPanelVideoRenderer": {
                  "videoId": "v1",
                  "title": { "runs": [{ "text": "Track One" }] },
                  "longBylineText": { "runs": [{ "text": "Artist A" }] },
                  "lengthText": { "runs": [{ "text": "2:00" }] }
                }
              },
              {
                "playlistPanelVideoRenderer": {
                  "videoId": "v2",
                  "selected": true,
                  "title": { "runs": [{ "text": "Track Two" }] },
                  "longBylineText": { "runs": [{ "text": "Artist B" }] },
                  "lengthText": { "runs": [{ "text": "3:00" }] }
                }
              }
            ]
          }
        }
        """
        let result = P.queueResult(from: JSONValue.parse(Data(json.utf8)))
        XCTAssertEqual(result.tracks.map(\.videoId), ["v1", "v2"])
        XCTAssertEqual(result.currentIndex, 1)
        XCTAssertEqual(result.tracks[1].artistLine, "Artist B")
        XCTAssertEqual(result.tracks[0].durationSeconds, 120)
    }
}
