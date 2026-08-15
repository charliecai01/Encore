// Creates (or, on later runs, rotates) the "R&B by Sonnet5" playlist: 100
// songs — 80 R&B songs split evenly across five decades (1980s–2020s, 16
// each), plus fixed quotas of 15 Taylor Swift songs and 5 Olivia Dean songs
// (Charlie's rule, 2026-08-13). Refreshed to a different window once a
// month via MonthlyRotation.
//
// Idempotent by design: finds the playlist by title in the signed-in
// library. Missing → create + populate. Present → reconcile (add whatever
// this month's selection is missing, remove whatever it dropped). The same
// invocation is meant to be re-run monthly.
//
// Stability: the live catalog (search results, genre pages, sub-playlists)
// is NOT stable across fetches — two calls minutes apart can return
// different content. So the chosen 100 for a given calendar month is
// cached to a local state file on first derivation and REUSED verbatim on
// every later run within that same month — the pool is only re-fetched
// when the month actually changes (or `--force` is passed, e.g. right
// after changing the selection rules mid-month). Without this, re-running
// the tool would each time derive a different fresh selection, ballooning
// the playlist instead of leaving it alone.
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
// Usage: swift run encore-playlist-tool [--dry-run] [--force]
import Foundation
import EncoreCore

let playlistTitle = "R&B by Sonnet5"
let dryRun = CommandLine.arguments.contains("--dry-run")
let forceRefresh = CommandLine.arguments.contains("--force")

// MARK: - Composition rule

struct EraSpec { let label: String; let query: String }
let eras: [EraSpec] = [
    EraSpec(label: "1980s", query: "80s R&B"),
    EraSpec(label: "1990s", query: "90s R&B"),
    EraSpec(label: "2000s", query: "2000s R&B"),
    EraSpec(label: "2010s", query: "2010s R&B"),
    EraSpec(label: "2020s", query: "2020s R&B"),
]
let eraQuota = 16              // 5 eras × 16 = 80
let maxPerArtistInEra = 2      // keep any one era from being one artist's greatest hits

struct ArtistQuota { let name: String; let count: Int }
let artistQuotas: [ArtistQuota] = [
    ArtistQuota(name: "Taylor Swift", count: 15),
    ArtistQuota(name: "Olivia Dean", count: 5),
]
let targetCount = eras.count * eraQuota + artistQuotas.map(\.count).reduce(0, +)   // 100

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
    /// The playlist this tool last synced, remembered so a RENAME doesn't
    /// make the next run miss it and create a duplicate. Charlie renamed
    /// "R&B by Sonnet5" → "R&B by Sonnet" on 2026-08-14, which title-only
    /// lookup would have silently turned into a second playlist. Optional so
    /// snapshots written before this field existed still decode.
    var playlistId: String?
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

// MARK: - Pool helpers

/// Title with any trailing "(...)"/"[...]" qualifier stripped and
/// lowercased — collapses "Anti-Hero", "Song (Live)", "Song (Acoustic)" and
/// "Song (Radio Edit)" to the same key so different uploads of the same
/// song don't each burn a separate dedup/quota slot.
func normalizedTitle(_ title: String) -> String {
    var t = title
    if let i = t.firstIndex(of: "(") { t = String(t[..<i]) }
    if let i = t.firstIndex(of: "[") { t = String(t[..<i]) }
    return t.trimmingCharacters(in: .whitespaces).lowercased()
}

/// Dedupes by videoId AND by (artist, normalized title) — catches both
/// exact re-uploads and same-song/different-upload duplicates (a studio cut
/// plus a "(Live)" or "(Acoustic)" version showing up as if they were two
/// songs, which happened in practice with Olivia Dean's smaller catalog).
/// Also drops unplayable rows and caps songs per artist. Preserves the
/// caller's input order — when a pool is built with the more trustworthy
/// source first (see `eraPool`), first-seen-wins dedup means that source is
/// what survives.
func curate(_ pool: [Track], maxPerArtist: Int) -> [Track] {
    var seenIds = Set<String>()
    var seenSongs = Set<String>()
    var perArtist: [String: Int] = [:]
    var out: [Track] = []
    for t in pool where !t.isUnavailable {
        guard seenIds.insert(t.videoId).inserted else { continue }
        let songKey = t.artistLine.lowercased() + "::" + normalizedTitle(t.title)
        guard seenSongs.insert(songKey).inserted else { continue }
        let n = perArtist[t.artistLine, default: 0]
        guard n < maxPerArtist else { continue }
        perArtist[t.artistLine] = n + 1
        out.append(t)
    }
    return out
}

/// A decade+genre query (e.g. "90s R&B"), pulled from human-curated
/// playlists FIRST and a direct song search second. Editorial decade
/// playlists turned out to be much more era-disciplined than song search,
/// which favors semantic/"vibe" relevance and happily pulls in
/// adjacent-decade tracks (verified live: a plain "90s R&B" song search
/// included 2003-2004 tracks). Playlist tracks are ordered first so
/// `curate`'s dedup prefers them over a looser song-search match for the
/// same artist slot.
func eraPool(_ query: String) async -> [Track] {
    async let songsTask: [Track] = (try? await ytm.search(query, filter: .songs))?.shelves.flatMap(\.tracks) ?? []
    async let playlistsTask: [Track] = {
        guard let plResults = try? await ytm.search(query, filter: .playlists) else { return [] }
        let cards = plResults.shelves.flatMap(\.items).compactMap { item -> CardItem? in
            if case .card(let c) = item, c.kind == .playlist, c.playlistId != nil { return c }
            return nil
        }
        var fetched: [Track] = []
        await withTaskGroup(of: [Track].self) { group in
            for card in cards.prefix(6) {
                guard let pid = card.playlistId else { continue }
                group.addTask { (try? await ytm.playlist(id: pid))?.tracks ?? [] }
            }
            for await tracks in group { fetched.append(contentsOf: tracks) }
        }
        return fetched
    }()
    let (songs, playlists) = await (songsTask, playlistsTask)
    return playlists + songs
}

/// An artist's songs via their artist page (comprehensive, authoritative)
/// plus a direct song search as a top-up, filtered back down to songs
/// actually credited to them (a bare name search can surface covers or
/// "songs like X" results).
func artistPool(_ name: String) async -> [Track] {
    var pool: [Track] = []
    if let results = try? await ytm.search(name, filter: .artists) {
        var artistId: String?
        outer: for shelf in results.shelves {
            for item in shelf.items {
                if case .card(let c) = item, c.kind == .artist { artistId = c.browseId; break outer }
            }
        }
        if case .card(let c)? = results.top, c.kind == .artist { artistId = artistId ?? c.browseId }
        if let artistId, let page = try? await ytm.artist(browseId: artistId) {
            pool.append(contentsOf: page.shelves.flatMap(\.tracks))
        }
    }
    if let songResults = try? await ytm.search(name, filter: .songs) {
        let byThisArtist = songResults.shelves.flatMap(\.tracks)
            .filter { $0.artistLine.localizedCaseInsensitiveContains(name) }
        pool.append(contentsOf: byThisArtist)
    }
    return pool
}

/// The broad "R&B & soul" genre page plus its sub-playlists/mixes — a large
/// (hundreds of tracks), not era-targeted pool used only as a backfill if
/// an era search comes up short of its quota.
func generalRnbPool() async -> [Track] {
    guard let shelves = try? await ytm.genre(params: YTM.Genre.rnbParams) else { return [] }
    var pool: [Track] = shelves.flatMap(\.tracks)
    var subPlaylists: [CardItem] = []
    for shelf in shelves {
        for item in shelf.items {
            if case .card(let c) = item, (c.kind == .playlist || c.kind == .album), c.playlistId != nil {
                subPlaylists.append(c)
            }
        }
    }
    if pool.count < 300, !subPlaylists.isEmpty {
        var fetched: [Track] = []
        await withTaskGroup(of: [Track].self) { group in
            for card in subPlaylists.prefix(12) {
                guard let pid = card.playlistId else { continue }
                group.addTask { (try? await ytm.playlist(id: pid))?.tracks ?? [] }
            }
            for await tracks in group { fetched.append(contentsOf: tracks) }
        }
        pool.append(contentsOf: fetched)
    }
    return pool
}

// MARK: - Selection (only runs on a genuine cache miss, or --force)

func deriveFreshSelection() async -> [Track] {
    enum SegmentResult { case era(String, [Track]); case artist(String, [Track]) }

    var eraRaw: [String: [Track]] = [:]
    var artistRaw: [String: [Track]] = [:]
    await withTaskGroup(of: SegmentResult.self) { group in
        for era in eras {
            group.addTask { .era(era.label, await eraPool(era.query)) }
        }
        for q in artistQuotas {
            group.addTask { .artist(q.name, await artistPool(q.name)) }
        }
        for await result in group {
            switch result {
            case .era(let label, let tracks): eraRaw[label] = tracks
            case .artist(let name, let tracks): artistRaw[name] = tracks
            }
        }
    }

    var chosen: [Track] = []
    var chosenIds = Set<String>()
    var shortfall = 0

    print("--- R&B eras (target \(eraQuota)/era) ---")
    for era in eras {
        let raw = eraRaw[era.label] ?? []
        let curated = curate(raw, maxPerArtist: maxPerArtistInEra)
        let rotated = MonthlyRotation.rotate(curated)
        let picked = Array(rotated.prefix(eraQuota)).filter { chosenIds.insert($0.videoId).inserted }
        chosen.append(contentsOf: picked)
        shortfall += max(0, eraQuota - picked.count)
        print("  \(era.label): raw=\(raw.count) curated=\(curated.count) picked=\(picked.count)")
    }

    if shortfall > 0 {
        print("Short by \(shortfall) after era pools — backfilling from the general R&B pool.")
        let general = curate(await generalRnbPool(), maxPerArtist: maxPerArtistInEra)
        for t in MonthlyRotation.rotate(general) where shortfall > 0 {
            guard chosenIds.insert(t.videoId).inserted else { continue }
            chosen.append(t)
            shortfall -= 1
        }
    }

    print("--- Fixed artists ---")
    for q in artistQuotas {
        let raw = artistRaw[q.name] ?? []
        let curated = curate(raw, maxPerArtist: Int.max)   // single artist — no cap needed
        let rotated = MonthlyRotation.rotate(curated)
        let picked = Array(rotated.prefix(q.count)).filter { chosenIds.insert($0.videoId).inserted }
        chosen.append(contentsOf: picked)
        let short = picked.count < q.count ? "  ⚠️ short of \(q.count)" : ""
        print("  \(q.name): raw=\(raw.count) curated=\(curated.count) picked=\(picked.count)\(short)")
    }

    print("Total selected: \(chosen.count) (target \(targetCount))")
    return chosen
}

// MARK: - Main

Task {
    do {
        let nowMonth = MonthlyRotation.monthIndex()
        let previous = loadAllSnapshots()[playlistTitle]

        let chosen: [Track]
        if let previous, previous.monthIndex == nowMonth, !forceRefresh {
            chosen = previous.tracks.map { Track(videoId: $0.videoId, title: $0.title, artistLine: $0.artistLine) }
            print("Reusing this month's cached selection (\(chosen.count) songs) — no live re-derive.")
        } else {
            chosen = await deriveFreshSelection()
            guard chosen.count >= 50 else {
                print("FAIL: only derived \(chosen.count)/\(targetCount) songs — aborting rather than syncing a broken selection.")
                exit(1)
            }
        }

        if dryRun {
            print("\n--- DRY RUN: would sync these into \"\(playlistTitle)\" ---")
            for (i, t) in chosen.enumerated() {
                print("\(i + 1). \(t.title) — \(t.artistLine)")
            }
            exit(0)
        }

        // Find-or-create the playlist. Look it up by the id we synced last
        // time FIRST and fall back to the title — a playlist Charlie renamed
        // is still the same playlist, and title-only lookup would create a
        // duplicate ("R&B by Sonnet5" → "R&B by Sonnet", 2026-08-14). The
        // title fallback also tolerates that rename via a prefix match.
        let libraryPlaylists = (try? await ytm.libraryPlaylists()) ?? []
        let stem = HomeSections.pinnedPlaylistTitles.first { playlistTitle.hasPrefix($0) } ?? playlistTitle
        let existing = previous?.playlistId.flatMap { id in
            libraryPlaylists.first { $0.playlistId == id }
        } ?? libraryPlaylists.first { $0.title == playlistTitle }
            ?? libraryPlaylists.first { $0.title.hasPrefix(stem) }

        var playlistId: String
        var priorTracks: [Track] = []
        if let existing, let pid = existing.playlistId {
            playlistId = pid
            priorTracks = try await ytm.playlist(id: pid).tracks
            let renamed = existing.title == playlistTitle ? "" : " (now titled \"\(existing.title)\")"
            print("Found existing playlist \(pid)\(renamed) with \(priorTracks.count) tracks — reconciling.")
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
        }, playlistId: playlistId), forTitle: playlistTitle)

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
