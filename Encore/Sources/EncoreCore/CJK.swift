import Foundation

/// Simplified/Traditional Chinese interop using the system ICU transliterator,
/// so Taiwanese artists shown in Traditional are findable with Simplified
/// input (and vice versa).
public enum CJK {
    /// The Traditional form, or nil if the string has no Han characters or
    /// converting changes nothing.
    public static func toTraditional(_ s: String) -> String? {
        guard s.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return nil }
        guard let converted = s.applyingTransform(StringTransform("Hans-Hant"), reverse: false),
              converted != s else { return nil }
        return converted
    }

    public static func toSimplified(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
    }

    /// True if the string contains any Han (Chinese) characters.
    public static func hasHan(_ s: String) -> Bool {
        s.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    }

    /// Mandarin pinyin, ASCII and lowercased: "陶喆" → "tao zhe", "张惠妹" →
    /// "zhang hui mei". Latin text passes through unchanged, so this is safe
    /// to use as a sort key for a mixed list.
    ///
    /// Sorting Han by its raw code points is effectively random to a reader —
    /// pinyin is the order a Mandarin speaker expects.
    public static func pinyin(_ s: String) -> String {
        let latin = s.applyingTransform(StringTransform("Han-Latin; Latin-ASCII"), reverse: false) ?? s
        return latin.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Sort key for a name in a mixed English/Chinese list: Latin names come
    /// first alphabetically, then Han names by pinyin (Charlie's rule,
    /// 2026-08-16). The leading flag does the grouping; the string orders
    /// within each group.
    public static func nameSortKey(_ s: String) -> (Int, String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return hasHan(trimmed) ? (1, pinyin(trimmed)) : (0, trimmed.lowercased())
    }
}

public extension String {
    /// Lowercased and Han-normalized (traditional → simplified) for
    /// script-insensitive matching.
    var matchNormalized: String {
        CJK.toSimplified(lowercased())
    }

    /// `contains` against an already-normalized query.
    func matches(normalizedQuery: String) -> Bool {
        matchNormalized.contains(normalizedQuery)
    }
}
