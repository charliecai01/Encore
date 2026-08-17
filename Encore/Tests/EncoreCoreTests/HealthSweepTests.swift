import XCTest
@testable import EncoreCore

/// Full-app data-path health sweep: walks every screen's backing call against
/// the live signed-in account in one pass and prints anomalies as "SUSPECT".
/// READ-ONLY — it never mutates the account.
///
/// This is a diagnostic, not an assertion suite: it reports rather than fails,
/// so it is **opt-in** and stays out of a normal `swift test` (which would
/// otherwise pay ~16s and ~25 lines of noise for no pass/fail signal). Run it
/// when something feels wrong app-wide, or after touching Parsers/YTM:
///
///     ENCORE_HEALTH_SWEEP=1 swift test --filter HealthSweepTests
///
/// Then read the output: every `SUSPECT` line is a data path that came back
/// empty or malformed. `NOTE` lines are usually legitimate but worth an eye.
/// Nothing printed but `SWEEP` lines = the whole data layer is healthy.
///
/// Needs a cookie (see `TestCookie`); skips cleanly without one. If the whole
/// sweep looks broken, suspect an EXPIRED cookie before a parser regression —
/// refresh iOS/Sources/DevCredentials.swift.
final class HealthSweepTests: XCTestCase {

    private var savedCookie: String?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["ENCORE_HEALTH_SWEEP"] == "1" else {
            throw XCTSkip("opt-in: ENCORE_HEALTH_SWEEP=1 swift test --filter HealthSweepTests")
        }
        guard let cookie = TestCookie.resolve() else {
            throw XCTSkip("no test cookie — set ENCORE_TEST_COOKIE or fill iOS/Sources/DevCredentials.swift")
        }
        savedCookie = InnerTube.shared.cookieHeader
        InnerTube.shared.cookieHeader = cookie
        guard InnerTube.shared.isAuthenticated else {
            InnerTube.shared.cookieHeader = savedCookie
            throw XCTSkip("test cookie has no SAPISID — not a valid signed-in cookie")
        }
    }

    override func tearDown() {
        // Don't leak auth into the unauthenticated live tests in the same run.
        InnerTube.shared.cookieHeader = savedCookie
        savedCookie = nil
    }

    func testSweepEveryScreen() async throws {

        // ---- HOME ----
        let home = (try? await YTM.shared.home()) ?? []
        print("SWEEP home shelves=\(home.count) items=\(home.flatMap(\.items).count)")
        if home.isEmpty { print("SUSPECT home empty") }
        for s in home where s.items.isEmpty { print("SUSPECT home shelf '\(s.title)' has 0 items") }

        // ---- LIBRARY ----
        let playlists = (try? await YTM.shared.libraryPlaylists()) ?? []
        print("SWEEP playlists=\(playlists.map { $0.title })")
        if playlists.contains(where: { ["RDPN", "SE", "LM"].contains($0.playlistId ?? "") }) {
            print("SUSPECT hidden auto-playlists (episodes / Liked Music) still visible")
        }
        for p in playlists where p.playlistId == nil { print("SUSPECT playlist '\(p.title)' has no playlistId") }

        let songs = (try? await YTM.shared.librarySongs()) ?? []
        let albums = (try? await YTM.shared.libraryAlbums()) ?? []
        let artists = (try? await YTM.shared.libraryArtists()) ?? []
        let history = (try? await YTM.shared.history()) ?? []
        print("SWEEP songs=\(songs.count) albums=\(albums.count) artists=\(artists.count) historyShelves=\(history.count)")
        if songs.isEmpty { print("SUSPECT liked songs empty") }
        for t in songs.prefix(40) where t.videoId.isEmpty || t.title.isEmpty {
            print("SUSPECT malformed liked track '\(t.title)'")
        }
        let dupes = songs.count - Set(songs.map(\.videoId)).count
        if dupes > 0 { print("SUSPECT \(dupes) duplicate liked songs") }

        // ---- COLLECTION (each playlist, with continuation) ----
        for p in playlists.prefix(4) {
            guard let pid = p.playlistId else { continue }
            let page = (try? await YTM.shared.playlist(id: pid))
            let n = page?.tracks.count ?? -1
            let declared = p.subtitle
            print("SWEEP playlist '\(p.title)' parsed=\(n) subtitle='\(declared)' thumb=\(page?.thumbnailURL != nil)")
            if n <= 0 { print("SUSPECT playlist '\(p.title)' parsed \(n) tracks") }
            if page?.thumbnailURL == nil { print("SUSPECT playlist '\(p.title)' has no artwork") }
            // Declared-vs-parsed drift: a few missing is normal (tracks that went
            // unavailable), a large gap means continuation paging stopped early.
            if n > 0, let stated = Self.declaredTrackCount(in: declared) {
                let missing = stated - n
                if missing > 0 {
                    let line = "'\(p.title)' parsed \(n) of \(stated) declared (\(missing) missing)"
                    print(missing > max(10, stated / 10) ? "SUSPECT \(line)" : "NOTE \(line)")
                }
            }
            if let tracks = page?.tracks {
                // Greyed-out rows YouTube won't play. Expected to be small and
                // non-zero on a real library; a sudden 0 across every playlist
                // means the GREY_OUT policy moved and the parse went blind.
                let dead = tracks.filter(\.isUnavailable)
                if !dead.isEmpty {
                    print("NOTE '\(p.title)' has \(dead.count) unavailable: \(dead.prefix(5).map(\.title))")
                }
                let noId = tracks.filter { $0.videoId.isEmpty }.count
                if noId > 0 { print("SUSPECT '\(p.title)' has \(noId) tracks with no videoId") }
                let noSet = tracks.filter { ($0.setVideoId ?? "").isEmpty }.count
                if noSet == tracks.count && !tracks.isEmpty {
                    print("SUSPECT '\(p.title)' has NO setVideoIds — remove-from-playlist will fail")
                }
            }
        }

        // ---- ALBUM (from library) ----
        if let a = albums.first, let bid = a.browseId {
            let page = try? await YTM.shared.album(browseId: bid)
            print("SWEEP album '\(a.title)' tracks=\(page?.tracks.count ?? -1) thumb=\(page?.thumbnailURL?.absoluteString.suffix(28) ?? "nil")")
            if (page?.tracks.count ?? 0) == 0 { print("SUSPECT album parsed 0 tracks") }
        }

        // ---- ARTIST screen (page + bio + library match) ----
        if let art = artists.first {
            let bid = art.browseId.map { $0.hasPrefix("MPLA") ? String($0.dropFirst(4)) : $0 } ?? ""
            if !bid.isEmpty, let page = try? await YTM.shared.artist(browseId: bid) {
                let matched = songs.filter { ArtistMatch.matches($0, browseId: bid, pageName: page.name) }
                let bio = await ArtistInfo.summary(forName: page.name)
                print("SWEEP artist '\(page.name)' shelves=\(page.shelves.count) libraryMatches=\(matched.count) bio=\(bio != nil)")
                if page.shelves.isEmpty { print("SUSPECT artist page has no shelves") }
                if bio == nil { print("NOTE no Wikidata bio for '\(page.name)' (may be legitimate)") }
            }
        }

        // ---- SEARCH, every filter ----
        for f in YTM.SearchFilter.allCases {
            let r = try? await YTM.shared.search("周杰倫", filter: f)
            let n = r?.shelves.flatMap(\.items).count ?? -1
            print("SWEEP search \(f.rawValue)=\(n)")
            if n <= 0 { print("SUSPECT search filter \(f.rawValue) returned \(n)") }
        }

        // ---- R&B (the Explore/Home section) ----
        let genre = (try? await YTM.shared.genre(params: YTM.Genre.rnbParams)) ?? []
        let remixes = (try? await YTM.shared.search("R&B remix mix", filter: .videos))?.shelves.flatMap(\.items) ?? []
        print("SWEEP rnb genreShelves=\(genre.count) remixItems=\(remixes.count)")
        if genre.isEmpty { print("SUSPECT R&B genre page empty — params may have drifted") }
        if remixes.isEmpty { print("SUSPECT R&B remix search empty") }
        for s in genre.prefix(4) where s.items.isEmpty { print("SUSPECT R&B shelf '\(s.title)' empty") }

        // ---- QUEUE / radio / lyrics for a real library track ----
        if let t = songs.first {
            let q = try? await YTM.shared.queue(videoId: t.videoId, playlistId: nil)
            print("SWEEP queue tracks=\(q?.tracks.count ?? -1) continuation=\(q?.continuation != nil) lyricsId=\(q?.lyricsBrowseId != nil)")
            if (q?.tracks.count ?? 0) == 0 { print("SUSPECT watch queue empty for a liked song") }
            let radio = try? await YTM.shared.radioQueue(for: t.videoId)
            print("SWEEP radio tracks=\(radio?.tracks.count ?? -1) continuation=\(radio?.continuation != nil)")
            if radio?.continuation == nil { print("SUSPECT radio has no continuation — endless autoplay would stall") }
            let lyr = await LyricsService.shared.lyrics(for: t)
            print("SWEEP lyrics for '\(t.title.prefix(20))' source=\(lyr?.source.rawValue ?? "none") synced=\(lyr?.lines?.count ?? 0)")
        }

        // ---- SORTS ----
        let most = LibrarySort.sort(songs, by: .mostPlayed)
        let least = LibrarySort.sort(songs, by: .leastPlayed)
        print("SWEEP sort mostPlayed[0]='\(most.first?.title.prefix(24) ?? "-")' leastPlayed[0]='\(least.first?.title.prefix(24) ?? "-")'")
        if most.count != songs.count || least.count != songs.count { print("SUSPECT play-count sort dropped tracks") }
        // Play counts are per-device, so a test process has none and both ends
        // tie. Only meaningful when run somewhere with a play history.
        if let a = most.first, let b = least.first, a.videoId == b.videoId, songs.count > 1 {
            print("NOTE most/least played tie — no local play counts in this process")
        }

        // ---- DISCOVER shelf source ----
        let pool = await YTM.shared.discoverPool(seeds: Array(songs.prefix(3).map(\.videoId)))
        print("SWEEP discoverPool=\(pool.count)")
        if pool.isEmpty { print("SUSPECT discover pool empty — Home Discover shelf would vanish") }
    }

    /// Pulls the track total out of a library subtitle like
    /// "Charlie Cai • 692 tracks". Nil for auto-playlists ("Auto playlist").
    private static func declaredTrackCount(in subtitle: String) -> Int? {
        let parts = subtitle.split(whereSeparator: { !$0.isNumber })
        guard subtitle.localizedCaseInsensitiveContains("track"),
              let n = parts.compactMap({ Int($0) }).max() else { return nil }
        return n
    }
}
