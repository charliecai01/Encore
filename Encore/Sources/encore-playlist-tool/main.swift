// Creates (or, on later runs, rotates) the "R&B by Sonnet5" playlist: ~100
// songs curated from YouTube Music's live "R&B & soul" genre page, refreshed
// to a different ~100 window once a month via MonthlyRotation.
//
// Idempotent by design: finds the playlist by title in the signed-in
// library. Missing → create + populate. Present → reconcile (add whatever
// this month's selection is missing, remove whatever it dropped). The same
// invocation is meant to be re-run monthly.
//
// Stability: the live genre page (direct shelves + the sub-playlists/mixes
// it expands into) is NOT stable across fetches — two calls minutes apart
// can return different content. So the chosen 100 for a given calendar
// month is cached to a local state file on first derivation and REUSED
// verbatim on every later run within that same month — the pool is only
// re-fetched when the month actually changes. Without this, re-running the
// tool mid-month (e.g. while testing) would each time add a different fresh
// ~100, ballooning the playlist instead of leaving it alone.
//
// Safety: this tool must never remove a track it didn't add itself — a
// playlist can carry songs the user put there by hand (or from some other
// flow), and "not in this month's rotation" is not license to delete them.
// The same state file records which videoIds THIS TOOL selected last time;
// only those are candidates for removal on a rotation. Anything else in the
// playlist — including the cache miss case (no prior snapshot) — is left
// alone, forever, no matter what.
//
// Auth: ENCORE_TEST_COOKIE env var, else the local (skip-worktree'd)
// iOS/Sources/DevCredentials.swift — same lookup as the test suite's
// TestCookie, duplicated here because executable targets can't import the
// test target. Never printed.
//
// Usage: swift run encore-playlist-tool [--dry-run]
import Foundation
import EncoreCore

let playlistTitle = "R&B by Sonnet5"
let targetCount = 100
let maxPerArtist = 4
let dryRun = CommandLine.arguments.contains("--dry-run")

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/encore-playlist-tool
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // Encore
let stateURL = repoRoot.appendingPathComponent(".encore-playlist-tool-state.json")

// MARK: - Monthly snapshot cache (keyed by playlist title, not id — the id
// doesn't exist yet the first time we ever run).

struct CachedTrack: Codable {
    var videoId: String
    var title: String
    var artistLine: String
}

struct RotationSnapshot: Codable {
    var monthIndex: Int
    var tracks: [CachedTrack]
}

func loadAllSnapshots() -> [String: RotationSnapshot] {
    guard let data = try? Data(contentsOf: stateURL),
          let decoded = try? JSONDecoder().decode([String: RotationSnapshot].self, from: data)
    else { return [:] }
    return decoded
}

func saveSnapshot(_ snapshot: RotationSnapshot, forTitle title: String) {
    var all = loadAllSnapshots()
    all[title] = snapshot
    guard let data = try? JSONEncoder().encode(all) else { return }
    try? data.write(to: stateURL)
}

func resolveCookie() -> String? {
    if let env = ProcessInfo.processInfo.environment["ENCORE_TEST_COOKIE"], !env.isEmpty {
        return env
    }
    let url = repoRoot.appendingPathComponent("iOS/Sources/DevCredentials.swift")
    guard let src = try? String(contentsOf: url, encoding: .utf8),
          let open = src.range(of: "static let cookie = \""),
          let close = src.range(of: "\"", range: open.upperBound..<src.endIndex)
    else { return nil }
    let cookie = String(src[open.upperBound..<close.lowerBound])
    return cookie.isEmpty ? nil : cookie
}

guard let cookie = resolveCookie() else {
    print("FAIL: no cookie found (set ENCORE_TEST_COOKIE or restore the local iOS/Sources/DevCredentials.swift).")
    exit(1)
}
InnerTube.shared.cookieHeader = cookie

let ytm = YTM.shared

// MARK: - Diagnostics

if let checkId = CommandLine.arguments.first(where: { $0.hasPrefix("--check=") })?.dropFirst("--check=".count) {
    Task {
        let page = try await ytm.playlist(id: String(checkId))
        // Rows with no setVideoId aren't real playlist entries — YouTube tacks
        // a "suggested songs" shelf onto the same response (a separate
        // continuation from the real track list), and the parser doesn't
        // distinguish it here. Flag them so a count doesn't look off.
        let real = page.tracks.filter { $0.setVideoId != nil }
        print("TITLE: \(page.title)  REAL COUNT: \(real.count)  (raw parse: \(page.tracks.count))")
        for (i, t) in page.tracks.enumerated() {
            let tag = t.setVideoId == nil ? "  [suggestion, not actually in the playlist]" : ""
            print("\(i + 1). \(t.title) — \(t.artistLine) [\(t.videoId)]\(tag)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--list-playlists") {
    Task {
        let all = try await ytm.libraryPlaylists()
        print("Library has \(all.count) playlists:")
        for c in all {
            print("  \"\(c.title)\"  id=\(c.playlistId ?? "nil")  subtitle=\(c.subtitle)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

// MARK: - Pool derivation (only runs on a genuine cache miss)

func deriveFreshSelection() async throws -> [Track] {
    let shelves = try await ytm.genre(params: YTM.Genre.rnbParams)
    print("Fetched \(shelves.count) R&B shelves: \(shelves.map(\.title).joined(separator: ", "))")

    var pool: [Track] = shelves.flatMap(\.tracks)
    var subPlaylists: [CardItem] = []
    for shelf in shelves {
        for item in shelf.items {
            if case .card(let c) = item, (c.kind == .playlist || c.kind == .album), c.playlistId != nil {
                subPlaylists.append(c)
            }
        }
    }
    print("Direct pool: \(pool.count) tracks; \(subPlaylists.count) sub-playlists/mixes available to expand into")

    if pool.count < targetCount * 3, !subPlaylists.isEmpty {
        let expandInto = Array(subPlaylists.prefix(12))
        var fetched: [Track] = []
        await withTaskGroup(of: [Track].self) { group in
            for card in expandInto {
                guard let pid = card.playlistId else { continue }
                group.addTask { (try? await ytm.playlist(id: pid))?.tracks ?? [] }
            }
            for await tracks in group { fetched.append(contentsOf: tracks) }
        }
        print("Expanded into \(expandInto.count) sub-playlists: +\(fetched.count) tracks")
        pool.append(contentsOf: fetched)
    }

    // Dedupe, drop unplayable rows, cap per-artist for variety. Sorted by
    // videoId first so the rotation window is keyed to a stable order, not
    // however this particular fetch happened to interleave shelves/mixes.
    var seenIds = Set<String>()
    var perArtist: [String: Int] = [:]
    var curated: [Track] = []
    for t in pool.sorted(by: { $0.videoId < $1.videoId }) where !t.isUnavailable && seenIds.insert(t.videoId).inserted {
        let n = perArtist[t.artistLine, default: 0]
        guard n < maxPerArtist else { continue }
        perArtist[t.artistLine] = n + 1
        curated.append(t)
    }
    print("Curated pool: \(curated.count) unique playable tracks (max \(maxPerArtist)/artist)")
    guard curated.count >= 60 else {
        throw NSError(domain: "encore-playlist-tool", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "curated pool too small (\(curated.count))"])
    }

    let rotated = MonthlyRotation.rotate(curated)
    return Array(rotated.prefix(targetCount))
}

// MARK: - Main

Task {
    do {
        let nowMonth = MonthlyRotation.monthIndex()
        let previous = loadAllSnapshots()[playlistTitle]

        let chosen: [Track]
        if let previous, previous.monthIndex == nowMonth {
            chosen = previous.tracks.map { Track(videoId: $0.videoId, title: $0.title, artistLine: $0.artistLine) }
            print("Reusing this month's cached selection (\(chosen.count) songs) — no live re-derive.")
        } else {
            chosen = try await deriveFreshSelection()
            print("Derived a fresh selection for month \(nowMonth): \(chosen.count) songs")
        }

        if dryRun {
            print("\n--- DRY RUN: would sync these into \"\(playlistTitle)\" ---")
            for (i, t) in chosen.enumerated() {
                print("\(i + 1). \(t.title) — \(t.artistLine)")
            }
            exit(0)
        }

        // Find-or-create the playlist.
        let libraryPlaylists = (try? await ytm.libraryPlaylists()) ?? []
        var playlistId: String
        var priorTracks: [Track] = []
        if let match = libraryPlaylists.first(where: { $0.title == playlistTitle }), let pid = match.playlistId {
            playlistId = pid
            priorTracks = try await ytm.playlist(id: pid).tracks
            print("Found existing playlist \(pid) with \(priorTracks.count) tracks — reconciling.")
        } else {
            guard let newId = try await ytm.createPlaylist(title: playlistTitle, privacy: "PRIVATE") else {
                print("FAIL: createPlaylist returned no id.")
                exit(1)
            }
            playlistId = newId
            print("Created playlist \(newId).")
        }

        // Reconcile: add what's missing, remove only what WE selected last
        // time and this month's rotation dropped. A track this tool never
        // selected — hand-added, or from anywhere else — is never touched.
        let managedLastTime = Set((previous?.tracks.map(\.videoId)) ?? [])
        let priorIds = Set(priorTracks.map(\.videoId))
        let chosenIds = Set(chosen.map(\.videoId))

        var added = 0, addFailed = 0
        for t in chosen where !priorIds.contains(t.videoId) {
            let ok = (try? await ytm.addToPlaylist(playlistId: playlistId, videoId: t.videoId)) ?? false
            if ok { added += 1 } else { addFailed += 1 }
        }

        var removed = 0, removeFailed = 0
        for t in priorTracks where managedLastTime.contains(t.videoId) && !chosenIds.contains(t.videoId) {
            let ok = (try? await ytm.removeFromPlaylist(playlistId: playlistId, videoId: t.videoId, setVideoId: t.setVideoId)) ?? false
            if ok { removed += 1 } else { removeFailed += 1 }
        }

        saveSnapshot(RotationSnapshot(monthIndex: nowMonth, tracks: chosen.map {
            CachedTrack(videoId: $0.videoId, title: $0.title, artistLine: $0.artistLine)
        }), forTitle: playlistTitle)

        print("\nDone. added=\(added) removed=\(removed) addFailed=\(addFailed) removeFailed=\(removeFailed) target=\(chosen.count)")
        print("\n--- Playlist contents this month ---")
        for (i, t) in chosen.enumerated() {
            print("\(i + 1). \(t.title) — \(t.artistLine)")
        }
        exit((addFailed > 0 || removeFailed > 0) ? 1 : 0)
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
