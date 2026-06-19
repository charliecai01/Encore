import XCTest
@testable import EncoreCore

/// End-to-end checks against live YouTube Music (unauthenticated). They verify
/// the connection works AND the parsers still understand the current response
/// shapes. Transport failures (offline / rate-limited) are skipped rather than
/// failed, so the suite stays green without a network; an empty parse from a
/// successful request is a real regression and DOES fail.
///
/// Set ENCORE_SKIP_LIVE=1 to skip these entirely (e.g. in offline CI).
final class LiveConnectionTests: XCTestCase {

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["ENCORE_SKIP_LIVE"] == "1" {
            throw XCTSkip("ENCORE_SKIP_LIVE set")
        }
    }

    /// Run `body`, turning transport-level errors into a skip.
    private func live(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let e as URLError {
            throw XCTSkip("network unavailable: \(e.code)")
        } catch let e as InnerTubeError {
            throw XCTSkip("YouTube Music unavailable: \(e)")
        }
    }

    func testLiveSearchSongs() async throws {
        try await live {
            let r = try await YTM.shared.search("daft punk", filter: .songs)
            let tracks = r.shelves.flatMap(\.tracks)
            XCTAssertFalse(tracks.isEmpty, "search returned no songs")
            XCTAssertFalse(tracks[0].videoId.isEmpty, "parsed track is missing a videoId")
        }
    }

    func testLiveAlbumPage() async throws {
        try await live {
            let results = try await YTM.shared.search("random access memories", filter: .albums)
            let album = results.shelves.flatMap(\.items).compactMap { item -> CardItem? in
                if case .card(let c) = item, c.kind == .album { return c }
                return nil
            }.first
            let browseId = try XCTUnwrap(album?.browseId, "no album result to open")
            let page = try await YTM.shared.album(browseId: browseId)
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.tracks.isEmpty, "album page parsed with no tracks")
        }
    }

    func testLiveRadioQueue() async throws {
        try await live {
            // Seed with a well-known videoId (Daft Punk – Get Lucky).
            let q = try await YTM.shared.radioQueue(for: "5NV6Rdv1a3I")
            XCTAssertFalse(q.tracks.isEmpty, "radio queue came back empty")
        }
    }

    func testLiveHomeShelves() async throws {
        try await live {
            let shelves = try await YTM.shared.home()
            XCTAssertFalse(shelves.isEmpty, "home returned no shelves")
        }
    }

    func testLiveSearchSuggestions() async throws {
        try await live {
            let s = try await YTM.shared.suggestions("billie")
            XCTAssertFalse(s.isEmpty, "no search suggestions returned")
        }
    }
}
