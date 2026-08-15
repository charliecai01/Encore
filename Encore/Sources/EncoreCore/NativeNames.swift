import Foundation
import os

/// Shows CJK artists under their native name — "张学友" rather than "Jacky
/// Cheung", "张惠妹" rather than "A-Mei" (Charlie's request, 2026-08-14).
///
/// Album and track credits come back romanized (`"Jacky Cheung"`), but
/// YouTube's own ARTIST entity carries both, combined: `"張學友 - Jacky
/// Cheung"`, `"張惠妹 - aMEI"`. So the native name is already in YouTube's
/// data — it just has to be looked up from the artist entity and split out.
/// Verified live 2026-08-14 against both of those artists.
///
/// The alternative — sending `hl=zh-Hans` on every InnerTube call — returns
/// clean native names but also translates everything else YouTube sends
/// ("Song" → 歌曲, "48M plays" → 播放次数：4825万), which is wrong for a
/// mixed English/Mandarin library. Hence this targeted lookup.
///
/// Names are normalized to SIMPLIFIED (Charlie's choice), so Jacky Cheung
/// reads 张学友 even though YouTube lists him Traditional as 張學友.
public enum NativeNames {

    /// Lowercased, stripped of everything but letters/digits — so "A-Mei",
    /// "aMEI" and "a mei" all compare equal. Used only for the romanized
    /// half of a name.
    public static func latinKey(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// The native (Han) portion of a YouTube artist entity title, in
    /// Simplified. `"張學友 - Jacky Cheung"` → `"张学友"`; `"周杰倫"` →
    /// `"周杰伦"`; `"Taylor Swift"` → nil.
    public static func nativePart(of title: String) -> String? {
        let separators = [" - ", " – ", " — ", " / ", "/"]
        var segments = [title]
        for sep in separators where title.contains(sep) {
            segments = title.components(separatedBy: sep)
            break
        }
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if CJK.hasHan(trimmed) { return CJK.toSimplified(trimmed) }
        }
        return nil
    }

    /// The romanized portion, if the title carries both halves.
    public static func latinPart(of title: String) -> String? {
        let separators = [" - ", " – ", " — ", " / ", "/"]
        for sep in separators where title.contains(sep) {
            for segment in title.components(separatedBy: sep) {
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                if !CJK.hasHan(trimmed), !latinKey(trimmed).isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Artists Charlie wants left under their romanized/stage name even
    /// though a Han form exists — A-Lin is billed that way everywhere, so
    /// "黄丽玲" reads wrong (his call, 2026-08-14). Keyed by `latinKey` and by
    /// both Han forms so it applies whichever direction the name arrives in.
    /// Keyed by `latinKey` and by the Simplified Han form, so it applies
    /// whichever direction the name arrives in — a track credited "黃麗玲"
    /// also displays as "A-Lin".
    public static let displayOverrides: [String: String] = [
        "alin": "A-Lin",
        "黄丽玲": "A-Lin",
    ]

    /// The name Charlie wants shown for this artist, when it's been pinned.
    public static func overrideName(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let hit = displayOverrides[CJK.toSimplified(trimmed)] { return hit }
        let key = latinKey(trimmed)
        return key.isEmpty ? nil : displayOverrides[key]
    }

    /// A song title with its translated/romanized half removed: "我恨我愛你 -
    /// Hate to Love You" → "我恨我愛你" (Charlie's call, 2026-08-14). The
    /// script is left exactly as YouTube listed it — only the English half
    /// goes. Titles without a separator, or without any Han, are untouched,
    /// so "P.S.我愛你" and "Hate to Love You" both survive intact.
    public static func displayTitle(_ title: String) -> String {
        guard CJK.hasHan(title) else { return title }
        let separators = [" - ", " – ", " — "]
        for sep in separators where title.contains(sep) {
            let segments = title.components(separatedBy: sep)
            // Keep every leading segment that has Han, drop the rest — a
            // title can legitimately be "甲 - 乙".
            let han = segments.prefix { CJK.hasHan($0) }
            if !han.isEmpty, han.count < segments.count {
                return han.joined(separator: sep).trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    /// The Simplified native name for `query` given a candidate artist-entity
    /// title, or nil when the candidate doesn't plausibly refer to the same
    /// artist. The match guard matters: a bare artist search happily returns
    /// somebody else, and silently relabelling one artist with another's name
    /// is worse than showing the romanized one.
    public static func resolve(entityTitle: String, query: String) -> String? {
        if let pinned = overrideName(for: query) { return pinned }
        guard let native = nativePart(of: entityTitle) else { return nil }
        if let pinned = overrideName(for: native) { return pinned }
        // A query that's already Han just needs normalizing.
        if CJK.hasHan(query) {
            let q = CJK.toSimplified(query.trimmingCharacters(in: .whitespaces))
            return native.contains(q) || q.contains(native) ? native : nil
        }
        let queryKey = latinKey(query)
        guard !queryKey.isEmpty else { return nil }
        // Compare against the romanized half when there is one; otherwise the
        // entity is native-only and there's nothing to verify against, so
        // don't guess.
        guard let latin = latinPart(of: entityTitle) else { return nil }
        let latinKeyValue = latinKey(latin)
        guard !latinKeyValue.isEmpty else { return nil }
        return latinKeyValue == queryKey
            || latinKeyValue.contains(queryKey)
            || queryKey.contains(latinKeyValue) ? native : nil
    }

    // MARK: - Lookup

    /// romanized name → native name ("" = known miss, e.g. every English
    /// artist). Same scoped async-safe lock ArtistInfo uses; NSLock can't be
    /// held across an await under the Swift 6 language mode.
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Persisted so the lookups survive relaunches — the answer for a given
    /// artist never changes, and Charlie prefers storage over spinners.
    /// The version suffix invalidates everything when the RULES change (v2
    /// added the romanized-preferred overrides), since old entries were
    /// computed under the old rules.
    private static let defaultsKey = "nativeArtistNames.v2"

    private static func loadPersisted() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func persist(_ key: String, _ value: String) {
        var all = loadPersisted()
        all[key] = value
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    /// The Simplified native name for `name`, or nil if there isn't one (an
    /// English-language artist) or it can't be verified. Cached in memory and
    /// on disk, including misses, so each artist costs one search once.
    ///
    /// Never throws and never blocks a view: callers show the romanized name
    /// and swap this in when it arrives.
    public static func native(for name: String) async -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let hit = cache.withLock({ $0[key] }) { return hit.isEmpty ? nil : hit }
        if let saved = loadPersisted()[key] {
            cache.withLock { $0[key] = saved }
            return saved.isEmpty ? nil : saved
        }
        // A pinned display name short-circuits everything — no network.
        if let pinned = overrideName(for: name) {
            cache.withLock { $0[key] = pinned }
            persist(key, pinned)
            return pinned
        }
        // A name that's already Han only needs normalizing — no network.
        if CJK.hasHan(name) {
            let native = CJK.toSimplified(name.trimmingCharacters(in: .whitespaces))
            cache.withLock { $0[key] = native }
            persist(key, native)
            return native
        }

        var resolved = ""
        if let results = try? await YTM.shared.search(name, filter: .artists) {
            var candidates: [String] = []
            if case .card(let top)? = results.top, top.kind == .artist { candidates.append(top.title) }
            for shelf in results.shelves {
                for item in shelf.items {
                    if case .card(let c) = item, c.kind == .artist { candidates.append(c.title) }
                }
            }
            for candidate in candidates.prefix(5) {
                if let native = resolve(entityTitle: candidate, query: name) {
                    resolved = native
                    break
                }
            }
        }
        cache.withLock { $0[key] = resolved }
        persist(key, resolved)
        return resolved.isEmpty ? nil : resolved
    }

    /// Best-effort display name: the native one when known, otherwise what
    /// was passed in.
    public static func display(for name: String) async -> String {
        await native(for: name) ?? name
    }

    // MARK: - Synchronous access for views

    /// Loads the persisted map into memory. Call once at launch so the
    /// synchronous lookups below can answer without touching the network.
    public static func seedFromDisk() {
        let saved = loadPersisted()
        guard !saved.isEmpty else { return }
        cache.withLock { current in
            for (k, v) in saved where current[k] == nil { current[k] = v }
        }
    }

    /// The native name if it's ALREADY resolved, without doing any work.
    /// Views call this: they render whatever they have now, and re-render
    /// when `warmUp` reports that more names arrived.
    public static func cached(for name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        guard let hit = cache.withLock({ $0[key] }) else { return nil }
        return hit.isEmpty ? nil : hit
    }

    /// `name` rewritten for display if a native form is already known.
    public static func displayCached(_ name: String) -> String {
        cached(for: name) ?? name
    }

    /// Rewrites every known artist name inside a composed string — album
    /// subtitles arrive pre-joined ("Jacky Cheung • Album • 2004"), so the
    /// artist can only be swapped by substitution.
    public static func rewriting(_ text: String, artists: [String]) -> String {
        var out = text
        for artist in artists {
            guard let native = cached(for: artist), !artist.isEmpty else { continue }
            out = out.replacingOccurrences(of: artist, with: native)
        }
        return out
    }

    /// Resolves `names` that aren't cached yet, a few at a time so a library
    /// full of artists doesn't fire hundreds of simultaneous searches.
    /// Returns true if anything new was learned, so the caller can trigger a
    /// re-render. Every result (including misses) is persisted, so this is
    /// effectively one-time per artist.
    @discardableResult
    public static func warmUp(names: [String], limit: Int = 60) async -> Bool {
        seedFromDisk()
        var pending: [String] = []
        var seen = Set<String>()
        for name in names {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if cache.withLock({ $0[key] }) == nil { pending.append(name) }
        }
        guard !pending.isEmpty else { return false }

        var learned = false
        for chunk in stride(from: 0, to: min(pending.count, limit), by: 4).map({
            Array(pending[$0..<min($0 + 4, min(pending.count, limit))])
        }) {
            await withTaskGroup(of: Bool.self) { group in
                for name in chunk {
                    group.addTask { await native(for: name) != nil }
                }
                for await found in group where found { learned = true }
            }
        }
        return learned
    }
}
