import XCTest
@testable import EncoreCore

/// Signed-in end-to-end checks against live YouTube Music, using a real
/// account cookie. They cover what the unauthenticated LiveConnectionTests
/// can't reach: the signed-in response shapes for the library, personalized
/// home/history, authoritative like state, and playlist continuation scoping
/// (signed-in playlists carry a separate "suggestions" continuation that the
/// parser must not confuse with the track-shelf one).
///
/// The cookie is looked up at RUNTIME and never ships in the repo:
///   1. the ENCORE_TEST_COOKIE environment variable, if set
///   2. the local (skip-worktree'd) iOS/Sources/DevCredentials.swift
/// With no cookie available the whole class skips, so CI and fresh checkouts
/// stay green. ENCORE_SKIP_LIVE=1 skips too. All tests are READ-ONLY — they
/// never mutate the account.
///
/// If these fail while the unauthenticated live tests pass, first suspect an
/// EXPIRED cookie (refresh DevCredentials.swift), then a signed-in parse
/// regression.
final class AuthenticatedLiveTests: XCTestCase {

    // MARK: - Auth plumbing

    private static var savedCookie: String?

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["ENCORE_SKIP_LIVE"] == "1" {
            throw XCTSkip("ENCORE_SKIP_LIVE set")
        }
        guard let cookie = Self.testCookie() else {
            throw XCTSkip("no test cookie — set ENCORE_TEST_COOKIE or fill iOS/Sources/DevCredentials.swift")
        }
        Self.savedCookie = InnerTube.shared.cookieHeader
        InnerTube.shared.cookieHeader = cookie
        guard InnerTube.shared.isAuthenticated else {
            InnerTube.shared.cookieHeader = Self.savedCookie
            throw XCTSkip("test cookie has no SAPISID — not a valid signed-in cookie")
        }
    }

    override func tearDown() {
        // Don't leak auth into the unauthenticated live tests in the same run.
        InnerTube.shared.cookieHeader = Self.savedCookie
        Self.savedCookie = nil
        super.tearDown()
    }

    /// ENCORE_TEST_COOKIE, else the string literal out of the local
    /// DevCredentials.swift (committed empty; real value is skip-worktree'd).
    /// Reading the app's copy keeps the secret in exactly one place.
    private static func testCookie() -> String? {
        if let env = ProcessInfo.processInfo.environment["ENCORE_TEST_COOKIE"],
           !env.isEmpty { return env }
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/EncoreCoreTests/AuthenticatedLiveTests.swift
            .deletingLastPathComponent()            // Tests/EncoreCoreTests
            .deletingLastPathComponent()            // Tests
            .deletingLastPathComponent()            // Encore
            .appendingPathComponent("iOS/Sources/DevCredentials.swift")
        guard let src = try? String(contentsOf: url, encoding: .utf8),
              let open = src.range(of: "static let cookie = \""),
              let close = src.range(of: "\"", range: open.upperBound..<src.endIndex)
        else { return nil }
        let cookie = String(src[open.upperBound..<close.lowerBound])
        return cookie.isEmpty ? nil : cookie
    }

    /// Run `body`, turning transport-level errors into a skip (same policy as
    /// LiveConnectionTests): offline/rate-limited isn't a parse regression.
    private func live(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let e as URLError {
            throw XCTSkip("network unavailable: \(e.code)")
        } catch let e as InnerTubeError {
            throw XCTSkip("YouTube Music unavailable: \(e)")
        }
    }

    /// Liked songs are used by two tests; fetch once per run (they can be many
    /// continuation pages).
    private static var likedSongsCache: [Track]?
    private func likedSongs() async throws -> [Track] {
        if let cached = Self.likedSongsCache { return cached }
        let songs = try await YTM.shared.librarySongs()
        Self.likedSongsCache = songs
        return songs
    }

    private static let expiredHint =
        "— if the unauthenticated live tests pass, the dev cookie likely expired; refresh DevCredentials.swift"

    // MARK: - Library

    func testLibraryPlaylistsParse() async throws {
        try await live {
            let cards = try await YTM.shared.libraryPlaylists()
            XCTAssertFalse(cards.isEmpty, "library playlists empty \(Self.expiredHint)")
            for card in cards {
                XCTAssertFalse(card.title.isEmpty, "playlist card with empty title")
                XCTAssertFalse(card.id.isEmpty, "playlist card with empty id")
            }
            XCTAssertTrue(cards.contains { $0.kind == .playlist },
                          "no card parsed as kind .playlist")
        }
    }

    // MARK: - Likes

    func testLikedSongsParseAndWatchQueueLikeCanary() async throws {
        try await live {
            let songs = try await likedSongs()
            XCTAssertFalse(songs.isEmpty, "liked songs empty \(Self.expiredHint)")
            for t in songs.prefix(30) {
                XCTAssertFalse(t.videoId.isEmpty, "liked track with empty videoId")
                XCTAssertFalse(t.title.isEmpty, "liked track with empty title")
            }

            // YouTube removed per-item likeStatus from watch responses
            // (verified live 2026-07-02: absent from every playlistPanel item,
            // even in the LM liked-songs panel; the top-level
            // likeButtonRenderer is an unpersonalized INDIFFERENT). So
            // currentLikeStatus is expected nil today and hearts ride on the
            // liked-library seed — see HANDOFF §5. This canary makes sure that
            // IF the field ever comes back, it carries correct data: a liked
            // song must report LIKE, never INDIFFERENT.
            guard let first = songs.first else { return }
            let q = try await YTM.shared.queue(videoId: first.videoId, playlistId: nil)
            XCTAssertFalse(q.tracks.isEmpty, "signed-in watch queue parsed no tracks")
            if let status = q.currentLikeStatus {
                XCTAssertEqual(status, "LIKE",
                               "watch response reports \(status) for a liked song — likeStatus is back but wrong/unpersonalized; don't trust it for hearts")
            }
        }
    }

    // MARK: - Personalized home / history

    func testHomeAndHistoryParseSignedIn() async throws {
        try await live {
            let shelves = try await YTM.shared.home()
            XCTAssertFalse(shelves.isEmpty, "signed-in home parsed no shelves")
            let items = shelves.flatMap(\.items)
            XCTAssertFalse(items.isEmpty, "signed-in home shelves are all empty")

            // History REQUIRES auth and is pure personal data — the strongest
            // signal that signed-in personalization parses.
            let history = try await YTM.shared.history()
            XCTAssertFalse(history.isEmpty, "history empty \(Self.expiredHint)")
            let tracks = history.flatMap(\.items).compactMap { item -> Track? in
                if case .track(let t) = item { return t }
                return nil
            }
            XCTAssertFalse(tracks.isEmpty, "history shelves contain no parsed tracks")
            XCTAssertFalse(tracks[0].videoId.isEmpty, "history track with empty videoId")
        }
    }

    // MARK: - Podcasts (feature re-enabled 2026-07-03)

    /// Library shows parse, and a show page yields episodes with the fields
    /// the podcast UI depends on: isEpisode (drives the dedicated Now Playing
    /// screen + transport), release date, and duration (drives the
    /// "N min left" progress rows).
    func testPodcastShowAndEpisodesParse() async throws {
        try await live {
            let cards = try await YTM.shared.libraryPodcasts()
            guard !cards.isEmpty else { throw XCTSkip("account has no library podcasts") }
            for card in cards.prefix(10) {
                XCTAssertFalse(card.title.isEmpty, "podcast card with empty title")
            }
            guard let show = cards.first(where: { $0.kind == .podcast && $0.browseId != nil }),
                  let browseId = show.browseId else {
                throw XCTSkip("no subscribed show card carries a browseId")
            }
            let page = try await YTM.shared.podcastShow(browseId: browseId)
            XCTAssertFalse(page.title.isEmpty, "show page parsed no title")
            XCTAssertFalse(page.tracks.isEmpty, "show page parsed no episodes")
            let sample = page.tracks.prefix(10)
            for ep in sample {
                XCTAssertTrue(ep.isEpisode, "show episode not flagged isEpisode — would get the SONG now-playing screen")
                XCTAssertFalse(ep.videoId.isEmpty, "episode with empty videoId")
                XCTAssertFalse(ep.title.isEmpty, "episode with empty title")
            }
            XCTAssertTrue(sample.contains { !($0.dateText ?? "").isEmpty },
                          "no episode carried a release date")
            XCTAssertTrue(sample.contains { ($0.durationSeconds ?? 0) > 0 },
                          "no episode carried a duration")
        }
    }

    /// "New Episodes" (playlistId RDPN) is an episode auto-playlist whose items
    /// use the podcast renderer the regular track parser skips. The merge in
    /// `YTM.playlist` is gated on `PodcastFeature.enabled` — with the flag off
    /// this page parses EMPTY, which was the original podcast bug. Guard the
    /// enabled path.
    func testNewEpisodesPlaylistMergesEpisodes() async throws {
        try await live {
            let wasEnabled = PodcastFeature.enabled
            PodcastFeature.enabled = true
            defer { PodcastFeature.enabled = wasEnabled }
            let page = try await YTM.shared.playlist(id: "RDPN")
            guard !page.tracks.isEmpty else {
                throw XCTSkip("New Episodes is empty right now — nothing to parse")
            }
            XCTAssertTrue(page.tracks.contains(where: \.isEpisode),
                          "RDPN items didn't parse as episodes — the gated podcastEpisodes merge regressed")
        }
    }

    // MARK: - Playlist continuations

    /// Signed-in collections paginate via continuation tokens, and signed-in
    /// playlists additionally carry a "suggestions" continuation the parser
    /// must NOT follow (the P.continuationToken scoping gotcha in HANDOFF §5).
    /// Prove multi-page fetches really accumulate: liked songs come back 25 per
    /// page, playlists 100 per page, so counts above those require working
    /// continuations.
    func testSignedInContinuationsAccumulate() async throws {
        try await live {
            var exercised = false

            let songs = try await likedSongs()
            if songs.count > 25 {
                exercised = true
                let unique = Set(songs.map(\.videoId))
                XCTAssertEqual(unique.count, songs.count,
                               "liked-songs continuation pages produced duplicates")
            }

            // Find a declared-big playlist from the library (subtitle carries
            // "N songs") and confirm the fetch crosses the 100-track page size.
            let cards = try await YTM.shared.libraryPlaylists()
            let declared: [(CardItem, Int)] = cards.compactMap { card in
                let digits = card.subtitle
                    .components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .compactMap { Int($0) }
                guard let n = digits.max() else { return nil }
                return (card, n)
            }
            if let big = declared.filter({ $0.1 >= 150 }).max(by: { $0.1 < $1.1 }) {
                exercised = true
                let id = big.0.playlistId ?? big.0.id
                let page = try await YTM.shared.playlist(id: id)
                XCTAssertGreaterThan(page.tracks.count, 100,
                                     "playlist declares \(big.1) songs but only \(page.tracks.count) parsed — continuation scoping broke?")
            }

            if !exercised {
                throw XCTSkip("account has no collection large enough to force a continuation page")
            }
        }
    }
}
