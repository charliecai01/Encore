// Creates (or, on later runs, rotates) the "R&B by Sonnet5" playlist: 200
// songs — 125 R&B songs split evenly across five decades (1980s–2020s, 25
// each), fixed quotas of 30 Taylor Swift and 20 Olivia Dean songs, and 25
// English-language songs from Korean R&B/neo-soul artists (Sam Kim, DEAN,
// Crush, Jay Park, Eric Nam, Henry Lau, John Park, Amber Liu) who sing
// substantially in English (2026-09-01) — the K-R&B pool filters out
// CJK-script tracks via `containsCJK`. Rap/hip-hop tracks, live/concert
// versions, music-video-type (OMV/UGC) rows, and a short hand-picked
// exclusion list (see `excludedRapArtists`/`excludedOtherArtists` below) are
// filtered out of every pool. Refreshed to a different window once a month
// via MonthlyRotation.
//
// History: 100-song ceiling (75 R&B @15/era + 15 Taylor + 10 Olivia)
// 2026-08-13, Olivia bumped 5→10 with era trimmed 16→15/era on 2026-08-21,
// doubled to a 200-song ceiling on 2026-08-31 with Taylor/Olivia bumped to
// 20/15 and a "Smooth Soul & Quiet Storm" English theme pool added (chasing
// the vibe of 陶喆/David Tao, who dominates Charlie's favorites but sings in
// Mandarin), then a K-R&B pool added 2026-09-01 pushing the total to 225.
// Charlie didn't like most of the 225-song result, so on 2026-09-02 the
// Quiet Storm theme pool was dropped entirely (most likely culprit — loose
// "vibe" searches pulling in off-target matches) and the remaining
// composition (era R&B + Taylor + Olivia + K-R&B) rebalanced back to a
// clean 200: Taylor/Olivia doubled from their original 100-song counts
// (15/10 → 30/20), R&B eras trimmed to 25/era, K-R&B held at 25 — same
// formula Charlie liked at 100, scaled up.
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
// History log: every time a rotation's content actually changes, the
// snapshot it's replacing is archived (most-recent-first, capped at
// `maxHistoryEntries`) instead of just being overwritten — see
// `PlaylistHistory`/`saveSnapshot`. `--list-history` prints what's
// recoverable; `--restore=<YYYY-MM>` re-syncs the playlist to an exact past
// selection (add this month's `--dry-run` first to preview it). Added
// 2026-09-02 after a mid-month rebalance destroyed the only record of the
// prior selection Charlie liked, with no way back to it.
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
//        swift run encore-playlist-tool --list-history
//        swift run encore-playlist-tool --restore=<YYYY-MM> [--dry-run]
import Foundation
import EncoreCore

let playlistTitle = "R&B by Sonnet5"
let dryRun = CommandLine.arguments.contains("--dry-run")
let forceRefresh = CommandLine.arguments.contains("--force")
/// Set by `--restore=<month>` below (before the main Task runs) to short-
/// circuit derivation entirely and sync that historical snapshot's tracks
/// instead.
var restoreSnapshot: RotationSnapshot?

// MARK: - Composition rule

struct EraSpec { let label: String; let query: String }
let eras: [EraSpec] = [
    EraSpec(label: "1980s", query: "80s R&B"),
    EraSpec(label: "1990s", query: "90s R&B"),
    EraSpec(label: "2000s", query: "2000s R&B"),
    EraSpec(label: "2010s", query: "2010s R&B"),
    EraSpec(label: "2020s", query: "2020s R&B"),
]
let eraQuota = 25              // 5 eras × 25 = 125
let maxPerArtistInEra = 2      // keep any one era from being one artist's greatest hits

struct ArtistQuota { let name: String; let count: Int }
let artistQuotas: [ArtistQuota] = [
    ArtistQuota(name: "Taylor Swift", count: 30),
    ArtistQuota(name: "Olivia Dean", count: 20),
]

// Korean R&B/neo-soul artists who sing substantially in English (Charlie,
// 2026-09-01). Picked for English-language output specifically, not K-R&B
// generally (most K-R&B is Korean-language, which `namedArtistsPool`'s CJK
// filter below would strip out anyway).
let koreanEnglishArtists: [String] = [
    // "Henry Lau" (full stage name), not bare "Henry" — that generic a
    // first name pulled in a raft of unrelated people also named Henry
    // (Henry Verus, Henry Morris, even the children's-book character
    // "Horrid Henry") both via the initial artist-page search and the
    // substring-based song-search fallback (Charlie, 2026-09-01).
    "Sam Kim", "DEAN", "Crush", "Jay Park", "Eric Nam", "Henry Lau", "John Park", "Amber Liu",
]
let koreanEnglishQuota = 25

let targetCount = eras.count * eraQuota + artistQuotas.map(\.count).reduce(0, +)
    + koreanEnglishQuota   // 200

// Artists whose catalog is overwhelmingly rap/hip-hop with spoken-word
// verses rather than sung R&B — Charlie doesn't want rap vocals in this
// playlist (2026-08-21), even though the era/genre searches above surface
// them as "vibe"-adjacent results (verified live: the era and general R&B
// pools pulled in a lot of hip-hop, mostly via feature credits — "Frontin'
// (feat. JAY-Z) — Pharrell Williams", "Ms. Jackson — Outkast", "Ray J
// 'Sexy Can I' featuring Yung Berg" (feature folded into a messy
// fan-uploaded title with no closing paren), etc.). A feature credit
// excludes the track same as a primary credit, since a rap verse anywhere
// in the song is still "people speaking words in it". Necessarily a
// best-effort, hand-maintained list — extend it if a future rotation still
// turns up rap tracks.
let excludedRapArtists: [String] = [
    "eminem", "dj khaled", "waka flocka flame", "rick ross", "wiz khalifa",
    "petey pablo", "ludacris", "run dmc", "run-d.m.c.", "dj paul",
    "ku$h drifter", "millyz", "fivio foreign", "seed of 6ix", "b.o.b",
    "queen nu", "omeretta the great", "snoop dogg", "t-pain", "roscoe dash",
    "wale", "styles p", "kanye west", "meek mill", "lil wayne", "50 cent",
    "jay-z", "fugees", "method man", "mase", "drake",
    "dr. dre", "queen pen", "slim thug", "ghostface killah", "nate dogg",
    "trife", "saigon", "ol' dirty bastard", "ol dirty bastard", "odb",
    "pras michel", "lil' kim", "lil kim", "fat joe", "kardinal offishall",
    "ja rule", "ying yang twins", "lil jon & the east side boyz", "lil jon",
    "the east side boyz", "boosie badazz", "remy ma", "terror squad",
    "fabolous", "flo rida", "styles of beyond", "fort minor", "afroman",
    "toosii", "kendrick lamar", "cardi b", "doechii", "21 savage", "outkast",
    "timbaland", "missy elliott", "jabba", "nelly", "busta rhymes", "dmx",
    "the game", "young jeezy", "jeezy", "t.i.", "gucci mane", "young thug",
    "future", "migos", "quavo", "offset", "takeoff", "travis scott",
    "tyler, the creator", "playboi carti", "lil baby", "lil durk", "polo g",
    "roddy ricch", "dababy", "megan thee stallion", "nicki minaj",
    "juicy j", "2 chainz", "big sean", "j. cole", "j cole", "common",
    "talib kweli", "mos def", "yasiin bey", "pusha t", "clipse",
    "rae sremmurd", "chief keef", "lil uzi vert", "trippie redd",
    "denzel curry", "vince staples", "earl sweatshirt", "schoolboy q",
    "ab-soul", "kodak black", "moneybagg yo", "lil tjay", "nba youngboy",
    "youngboy never broke again", "central cee", "stormzy", "skepta",
    "headie one", "aitch", "russ millions", "digga d", "cassidy",
    "will smith", "city high", "the black eyed peas", "black eyed peas",
    "madcon", "sean paul", "notorious b.i.g.", "biggie", "tupac", "2pac",
    "eazy-e", "ice cube", "nas", "puff daddy", "p. diddy", "diddy",
    "sean combs", "black rob", "mark curry", "the fresh prince",
    "dj jazzy jeff & the fresh prince", "left eye", "yg", "baby bash",
    "bone thugs-n-harmony", "bone thugs n harmony", "m.i.a.", "will.i.am",
    "eve", "ll cool j", "coolio", "n.w.a.", "n.w.a", "the notorious b.i.g.",
    "shaggy", "tyga", "foxy brown", "babytron", "so solid crew", "twista",
    "chingy", "tee grizzley", "m.o.p.", "mop", "cam'ron", "juelz santana",
    "freekey zeekey", "mc lyte", "jacques berman webster", "jacques webster",
    "lil flip", "yung berg", "soulja boy", "soulja boy tell'em", "g-unit",
    "bubba sparxxx", "whodini", "grandmaster flash",
    "grandmaster flash & the furious five", "the furious five", "young money",
    "lil yachty", "chance the rapper", "tory lanez", "childish gambino",
    "a$ap ferg", "asap ferg", "french montana", "andre 3000", "kodie shane",
    "chamillionaire", "krayzie bone", "big pun", "big punisher",
]

// Artists excluded for reasons other than genre: convicted of sex crimes
// against minors (r kelly), or name collisions with the K-R&B artists above.
let excludedOtherArtists: [String] = [
    "r kelly", "r. kelly",
    // "Crush 40" is the Sonic the Hedgehog game-soundtrack rock band, a name
    // collision with K-R&B singer Crush (김현우) — excluding the two-word
    // phrase leaves the real "Crush" untouched (2026-09-01).
    "crush 40",
    // AOMG/H1GHR crew rap features that ride along on a few Jay Park
    // tracks — those specific tracks are straight hip-hop posse cuts, not
    // R&B, even though Jay Park himself sings R&B elsewhere (2026-09-01).
    "lngshot", "haon", "sik-k", "ph-1", "woodie gohild", "trade l",
    // "Henry" and "Dean" are common enough names that an artist-name search
    // for K-R&B singers Henry (Lau) and DEAN also surfaces completely
    // unrelated people by the same first name (2026-09-01).
    "henry mancini", "henry freitas", "dean lewis", "dean brody", "jackson dean", "dean martin",
]

/// Splits normalized (diacritic-folded, lowercased) text into words on any
/// non-alphanumeric boundary — "B.O.B", "Jay-Z"/"Jaÿ-Z", "(feat. X)" and
/// "featuring X" (no parens at all, seen in messy fan-uploaded titles) all
/// reduce to the same word stream, so a single whole-word phrase match
/// against `excludedRapArtists` covers every credit style without needing
/// to parse "feat."/comma/parenthesis structure at all.
func words(_ text: String) -> [String] {
    let normalized = text.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
    return normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// True if `phrase`'s words appear as a contiguous run inside `haystack`.
/// Whole-word matching (not substring) so "nas" never matches inside
/// "Anastasia" — both are reduced to single words ("nas" vs "anastasia")
/// that only compare equal to each other, never partially.
func containsPhrase(_ haystack: [String], _ phrase: [String]) -> Bool {
    guard !phrase.isEmpty, haystack.count >= phrase.count else { return false }
    for start in 0...(haystack.count - phrase.count) where Array(haystack[start..<(start + phrase.count)]) == phrase {
        return true
    }
    return false
}

let excludedPhrases: [[String]] = (excludedRapArtists + excludedOtherArtists).map(words)

func isExcludedTrack(_ track: Track) -> Bool {
    let haystack = words(track.title + " " + track.artistLine)
    return excludedPhrases.contains { containsPhrase(haystack, $0) }
}

/// True if the title marks a live/concert recording rather than the studio
/// cut — "Song (Live)", "Song - Live at Wembley", "Song [Live Version]",
/// "Song (Live From Abbey Road)". Checked as a substring against the
/// lowercased title (not the word-boundary machinery above) since "live"
/// legitimately shows up as a plain word in the qualifier text, not as an
/// artist-name phrase (Charlie, 2026-09-02: don't want live versions in the
/// playlist at all, not just deduped against the studio version).
func isLiveVersion(_ title: String) -> Bool {
    let lower = title.lowercased()
    return lower.contains("(live") || lower.contains("[live")
        || lower.contains("- live") || lower.contains("live at ")
        || lower.contains("live from ") || lower.contains("live version")
}

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
    /// When this snapshot was actually synced live — purely informational,
    /// shown by `--list-history`. Optional so snapshots written before this
    /// field existed still decode.
    var syncedAt: Date?
}

/// Everything remembered for one generated playlist: the snapshot currently
/// live, plus a trail of past ones so a rotation can be rolled back. Added
/// 2026-09-02 after Charlie asked to revert to "the 100 songs from two weeks
/// ago" and there was no way to — the old format only ever kept ONE
/// snapshot, overwritten on every run, so the moment the tool ran again the
/// prior selection was gone for good. `history` is most-recent-first and
/// capped at `maxHistoryEntries`.
struct PlaylistHistory: Codable {
    var current: RotationSnapshot
    var history: [RotationSnapshot]
}
let maxHistoryEntries = 24   // two years of monthly rotations

func loadAllHistories() -> [String: PlaylistHistory] {
    guard let data = try? Data(contentsOf: stateURL) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let decoded = try? decoder.decode([String: PlaylistHistory].self, from: data) {
        return decoded
    }
    // Migrate the old bare-snapshot-per-title format transparently — it has
    // no history, but the current snapshot carries forward unchanged.
    if let legacy = try? decoder.decode([String: RotationSnapshot].self, from: data) {
        return legacy.mapValues { PlaylistHistory(current: $0, history: []) }
    }
    return [:]
}

/// Writes `snapshot` as the new current state for `title`. Whatever was
/// current before is pushed onto the front of `history` first, UNLESS its
/// track list is identical to the new one — that keeps a plain re-run (cache
/// hit, or a --force that happens to reproduce the same picks) from writing
/// a duplicate history entry, while still capturing every real content
/// change regardless of whether it happened to land in a new calendar month
/// (e.g. two --force reruns in the same month while iterating on the rule).
func saveSnapshot(_ snapshot: RotationSnapshot, forTitle title: String) {
    var all = loadAllHistories()
    var entry = all[title]
    if let previousCurrent = entry?.current,
       Set(previousCurrent.tracks.map(\.videoId)) != Set(snapshot.tracks.map(\.videoId)) {
        entry!.history.insert(previousCurrent, at: 0)
        entry!.history = Array(entry!.history.prefix(maxHistoryEntries))
    }
    if entry == nil {
        entry = PlaylistHistory(current: snapshot, history: [])
    } else {
        entry!.current = snapshot
    }
    all[title] = entry
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(all) else { return }
    try? data.write(to: stateURL)
}

/// monthIndex (year*12 + month) back to a "YYYY-MM" label for display.
func describeMonthIndex(_ monthIndex: Int) -> String {
    let year = (monthIndex - 1) / 12
    let month = ((monthIndex - 1) % 12) + 1
    return String(format: "%04d-%02d", year, month)
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

if CommandLine.arguments.contains("--list-history") {
    guard let entry = loadAllHistories()[playlistTitle] else {
        print("No history recorded for \"\(playlistTitle)\" yet.")
        exit(0)
    }
    func describe(_ label: String, _ snap: RotationSnapshot) {
        let synced = snap.syncedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown time"
        print("\(label)  month=\(describeMonthIndex(snap.monthIndex))  tracks=\(snap.tracks.count)  synced=\(synced)")
    }
    describe("CURRENT", entry.current)
    for h in entry.history { describe("history", h) }
    if entry.history.isEmpty {
        print("(No older snapshots yet — history starts accumulating from the next content change.)")
    } else {
        print("\nRestore one with: swift run encore-playlist-tool --restore=<month, e.g. \(describeMonthIndex(entry.history[0].monthIndex))>")
    }
    exit(0)
}

if let restoreArg = CommandLine.arguments.first(where: { $0.hasPrefix("--restore=") })?.dropFirst("--restore=".count) {
    guard let entry = loadAllHistories()[playlistTitle] else {
        print("FAIL: no history recorded for \"\(playlistTitle)\" — nothing to restore.")
        exit(1)
    }
    let target = String(restoreArg)
    let candidates = [entry.current] + entry.history
    guard let match = candidates.first(where: { describeMonthIndex($0.monthIndex) == target }) else {
        print("FAIL: no snapshot for month \"\(target)\". Available: \(candidates.map { describeMonthIndex($0.monthIndex) }.joined(separator: ", "))")
        exit(1)
    }
    print("Restoring the \(describeMonthIndex(match.monthIndex)) snapshot (\(match.tracks.count) tracks) as current...")
    restoreSnapshot = match
}

// One-time (or occasional) manual recovery command: deliberately bypasses
// the normal reconcile safety rule ("only remove a track this tool
// remembers selecting") and instead removes EVERY live track not in the
// CURRENT cached selection, no matter its provenance. Added 2026-09-02 after
// several forced re-derivations in a row (each landing on a different
// live-search-dependent pick, before the history log existed to track them
// all) left 146 stray tracks behind that the normal safety rule wouldn't
// touch. Explicit opt-in only — never run automatically.
if CommandLine.arguments.contains("--purge-unselected") {
    Task {
        guard let entry = loadAllHistories()[playlistTitle], let pid = entry.current.playlistId else {
            print("FAIL: no current snapshot/playlist id on record — nothing to purge against.")
            exit(1)
        }
        let keep = Set(entry.current.tracks.map(\.videoId))
        let page = try await ytm.playlist(id: pid)
        let toRemove = page.tracks.filter { !keep.contains($0.videoId) }
        print("Live playlist has \(page.tracks.count) tracks; \(keep.count) are in the current selection; removing \(toRemove.count) not selected.")
        var removed = 0, failed = 0
        for t in toRemove {
            let ok = (try? await ytm.removeFromPlaylist(playlistId: pid, videoId: t.videoId, setVideoId: t.setVideoId)) ?? false
            if ok { removed += 1 } else {
                failed += 1
                print("  remove failed for \(t.title) — \(t.artistLine) [\(t.videoId)]")
            }
        }
        print("Done. removed=\(removed) failed=\(failed)")
        exit(failed > 0 ? 1 : 0)
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
/// Also drops unplayable rows, live/concert versions, and music-video-type
/// (OMV/UGC) rows and caps songs per artist. The video-type exclusion is
/// pulling double duty: those rows are overwhelmingly messy fan uploads
/// ("Official HD Video", "Videoclip", channel names as the artist credit —
/// e.g. "Say My Name (Official Video) — Destiny's Child" uploaded by some
/// random channel) AND `addToPlaylist` reliably returns a non-SUCCEEDED
/// status for every one of them — confirmed 2026-09-02 when exactly the
/// video-type rows in that month's selection were the ones silently
/// failing to add. Preserves the caller's input order — when a pool is
/// built with the more trustworthy source first (see `eraPool`),
/// first-seen-wins dedup means that source is what survives.
func curate(_ pool: [Track], maxPerArtist: Int) -> [Track] {
    var seenIds = Set<String>()
    var seenSongs = Set<String>()
    var perArtist: [String: Int] = [:]
    var out: [Track] = []
    for t in pool where !t.isUnavailable && !isExcludedTrack(t) && !isLiveVersion(t.title) && !t.isVideo {
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

/// True if the text contains CJK characters — used to keep the K-R&B pool
/// (English-language by design) from pulling in Korean-language tracks off
/// these artists' catalogs.
func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x4E00...0x9FFF).contains(scalar.value)   // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(scalar.value)  // CJK Extension A
            || (0xAC00...0xD7A3).contains(scalar.value)  // Hangul (keep it English-only, not just non-Chinese)
    }
}

/// Merges each named artist's full catalog (via `artistPool`, so albums and
/// singles are included, not just a top-songs shelf) into one pool, then
/// keeps only the English-language tracks — these artists have Korean output
/// too, and this quota is specifically about their English songs.
func namedArtistsPool(_ names: [String]) async -> [Track] {
    var pool: [Track] = []
    await withTaskGroup(of: [Track].self) { group in
        for name in names {
            group.addTask { await artistPool(name) }
        }
        for await tracks in group { pool.append(contentsOf: tracks) }
    }
    // A "(Korean Version)" tag means Korean-language audio despite an
    // otherwise-Latin-script title, so containsCJK alone won't catch it.
    return pool.filter {
        !containsCJK($0.title) && !containsCJK($0.artistLine)
            && !$0.title.localizedCaseInsensitiveContains("korean version")
    }
}

/// A decade+genre query (e.g. "90s R&B"), pulled from human-curated
/// playlists FIRST and a direct song search second. Editorial decade
/// playlists turned out to be much more era-disciplined than song search,
/// which favors semantic/"vibe" relevance and happily pulls in
/// adjacent-decade tracks (verified live: a plain "90s R&B" song search
/// included 2003-2004 tracks). Playlist tracks are ordered first so
/// `curate`'s dedup prefers them over a looser song-search match for the
/// same artist slot.
/// Album title with trailing "(...)" qualifiers stripped and lowercased —
/// collapses "Fearless (Taylor's Version)", "Speak Now (Taylor's Version)
/// (Deluxe)", etc. down to the same era key as the original release, so a
/// re-recording or deluxe reissue doesn't create a whole separate era.
func albumEraKey(_ albumTitle: String) -> String {
    var t = albumTitle
    while let i = t.firstIndex(of: "(") { t = String(t[..<i]) }
    return t.trimmingCharacters(in: .whitespaces).lowercased()
}

/// Picks `count` tracks from `pool` spread evenly across the artist's
/// albums/eras (grouped by `albumEraKey`) instead of however the pool
/// happens to be ordered. Without this, an artist whose catalog includes a
/// couple of unusually large releases — e.g. Taylor Swift's Fearless/Speak
/// Now "Taylor's Version" re-recordings, each 20+ tracks once vault cuts are
/// counted — crowds out the rest of her eras purely by track count (Charlie,
/// 2026-09-02: "I want every era of Taylor to be represented"). Tracks with
/// no album info (raw song-search top-ups) land in one shared bucket.
/// Round-robins one track per era per pass, each era's own tracks in a
/// monthly-rotated order, so the pick stays fresh month to month without
/// ever systematically favoring one era over another.
func eraBalancedPick(_ pool: [Track], count: Int) -> [Track] {
    var buckets: [String: [Track]] = [:]
    for t in pool {
        let key = t.album.map { albumEraKey($0.name) } ?? "(no album)"
        buckets[key, default: []].append(t)
    }
    let keys = MonthlyRotation.rotate(buckets.keys.sorted())
    var remaining = buckets.mapValues { MonthlyRotation.rotate($0) }
    var out: [Track] = []
    while out.count < count {
        let before = out.count
        for key in keys where out.count < count {
            guard var bucket = remaining[key], !bucket.isEmpty else { continue }
            out.append(bucket.removeFirst())
            remaining[key] = bucket
        }
        if out.count == before { break }   // every era's bucket exhausted
    }
    return out
}

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
/// "songs like X" results). The artist page's own track shelves (e.g. "Top
/// songs") only list a couple dozen tracks even for a deep catalog, so this
/// also walks the "Albums" / "Singles & EPs" shelves and pulls every track
/// from each release — needed to fill a 30-song quota for an artist whose
/// top-songs shelf alone comes up short.
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
            let releaseCards = page.shelves
                .filter { $0.title == "Albums" || $0.title == "Singles & EPs" }
                .flatMap(\.items)
                .compactMap { item -> CardItem? in
                    if case .card(let c) = item, c.kind == .album || c.kind == .playlist { return c }
                    return nil
                }
            if !releaseCards.isEmpty {
                var releaseTracks: [Track] = []
                await withTaskGroup(of: [Track].self) { group in
                    for card in releaseCards.prefix(20) {
                        group.addTask {
                            if card.kind == .album, let bid = card.browseId {
                                return (try? await ytm.album(browseId: bid))?.tracks ?? []
                            } else if let pid = card.playlistId {
                                return (try? await ytm.playlist(id: pid))?.tracks ?? []
                            }
                            return []
                        }
                    }
                    for await tracks in group { releaseTracks.append(contentsOf: tracks) }
                }
                // Own-album/single track rows on YT Music often drop the artist
                // column entirely (it's implied by the page) — backfill it so
                // these tracks don't get lost to downstream artist-name checks.
                pool.append(contentsOf: releaseTracks.map { t in
                    var t = t
                    if t.artistLine.isEmpty { t.artistLine = name }
                    return t
                })
            }
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
    enum SegmentResult { case era(String, [Track]); case artist(String, [Track]); case koreanEnglish([Track]) }

    var eraRaw: [String: [Track]] = [:]
    var artistRaw: [String: [Track]] = [:]
    var koreanEnglishRaw: [Track] = []
    await withTaskGroup(of: SegmentResult.self) { group in
        for era in eras {
            group.addTask { .era(era.label, await eraPool(era.query)) }
        }
        for q in artistQuotas {
            group.addTask { .artist(q.name, await artistPool(q.name)) }
        }
        group.addTask { .koreanEnglish(await namedArtistsPool(koreanEnglishArtists)) }
        for await result in group {
            switch result {
            case .era(let label, let tracks): eraRaw[label] = tracks
            case .artist(let name, let tracks): artistRaw[name] = tracks
            case .koreanEnglish(let tracks): koreanEnglishRaw = tracks
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
        let picked = eraBalancedPick(curated, count: q.count).filter { chosenIds.insert($0.videoId).inserted }
        chosen.append(contentsOf: picked)
        let short = picked.count < q.count ? "  ⚠️ short of \(q.count)" : ""
        print("  \(q.name): raw=\(raw.count) curated=\(curated.count) picked=\(picked.count)\(short)")
    }

    print("--- K-R&B (English) ---")
    do {
        let curated = curate(koreanEnglishRaw, maxPerArtist: maxPerArtistInEra)
        let rotated = MonthlyRotation.rotate(curated)
        let picked = Array(rotated.prefix(koreanEnglishQuota)).filter { chosenIds.insert($0.videoId).inserted }
        chosen.append(contentsOf: picked)
        let short = picked.count < koreanEnglishQuota ? "  ⚠️ short of \(koreanEnglishQuota)" : ""
        print("  K-R&B (English): raw=\(koreanEnglishRaw.count) curated=\(curated.count) picked=\(picked.count)\(short)")
    }

    print("Total selected: \(chosen.count) (target \(targetCount))")
    return chosen
}

// MARK: - Main

Task {
    do {
        let nowMonth = MonthlyRotation.monthIndex()
        let previousEntry = loadAllHistories()[playlistTitle]
        let previous = previousEntry?.current

        let chosen: [Track]
        if let restoreSnapshot {
            chosen = restoreSnapshot.tracks.map { Track(videoId: $0.videoId, title: $0.title, artistLine: $0.artistLine) }
        } else if let previous, previous.monthIndex == nowMonth, !forceRefresh {
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
        // duplicate ("R&B by Sonnet5" → "R&B by Sonnet", 2026-08-14). A
        // transient fetch failure here must NOT fall through to the
        // create-new-playlist path below — it silently did exactly that on
        // 2026-08-31 and produced a second, duplicate playlist. This
        // specific call fails often right after a fresh derivation (dozens
        // of concurrent era/theme/artist fetches just ran on the same
        // client), so retry a few times before giving up (2026-09-01).
        var libraryPlaylists: [CardItem]?
        let backoffSeconds: [UInt64] = [10, 30, 60]
        for (i, delay) in backoffSeconds.enumerated() {
            do {
                libraryPlaylists = try await ytm.libraryPlaylists()
            } catch {
                print("libraryPlaylists() error: \(error)")
            }
            if libraryPlaylists != nil { break }
            if i < backoffSeconds.count - 1 {
                print("libraryPlaylists() fetch failed (attempt \(i + 1)/\(backoffSeconds.count)) — retrying in \(delay)s...")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        guard let libraryPlaylists else {
            print("FAIL: couldn't fetch library playlists after 3 attempts — aborting rather than risking a duplicate create.")
            exit(1)
        }
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

        // Reconcile: add what's missing, remove only what WE selected at
        // some point (this run or any retained past one) and this month's
        // rotation dropped. A track this tool never selected — hand-added,
        // or from anywhere else — is never touched. Widened from "just the
        // immediately-previous snapshot" to "every snapshot the history log
        // still retains" on 2026-09-02: several forced re-derivations in a
        // row (each landing on a different live-search-dependent selection)
        // left earlier runs' picks stranded — untracked by the time the NEXT
        // run only looked one snapshot back — and they piled up in the live
        // playlist with no way to clean them out short of hand-editing.
        let managedEver = Set((previousEntry.map { [$0.current] + $0.history } ?? [])
            .flatMap(\.tracks).map(\.videoId))
        let priorIds = Set(priorTracks.map(\.videoId))
        let chosenIds = Set(chosen.map(\.videoId))

        var added = 0, addFailed = 0
        for t in chosen where !priorIds.contains(t.videoId) {
            do {
                if try await ytm.addToPlaylist(playlistId: playlistId, videoId: t.videoId) {
                    added += 1
                } else {
                    addFailed += 1
                    print("  add failed (no error, bad status) for \(t.title) — \(t.artistLine) [\(t.videoId)]")
                }
            } catch {
                addFailed += 1
                print("  add threw for \(t.title) — \(t.artistLine) [\(t.videoId)]: \(error)")
            }
        }

        var removed = 0, removeFailed = 0
        for t in priorTracks where managedEver.contains(t.videoId) && !chosenIds.contains(t.videoId) {
            let ok = (try? await ytm.removeFromPlaylist(playlistId: playlistId, videoId: t.videoId, setVideoId: t.setVideoId)) ?? false
            if ok { removed += 1 } else { removeFailed += 1 }
        }

        saveSnapshot(RotationSnapshot(monthIndex: nowMonth, tracks: chosen.map {
            CachedTrack(videoId: $0.videoId, title: $0.title, artistLine: $0.artistLine)
        }, playlistId: playlistId, syncedAt: Date()), forTitle: playlistTitle)

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
