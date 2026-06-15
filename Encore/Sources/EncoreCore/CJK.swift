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
