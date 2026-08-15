import Foundation

/// Small display-only cleanups for the strings YouTube hands back
/// pre-joined, where the app wants a subset.
public enum DisplayText {

    /// A collection's stat line without its view count: "8.4K views • 692
    /// tracks • 49+ hours" → "692 tracks • 49+ hours".
    ///
    /// Play counts on a personal playlist are noise (Charlie's call,
    /// 2026-08-14) — it's your own list, the interesting parts are how many
    /// songs and how long. Albums keep theirs.
    public static func withoutViewCount(_ text: String) -> String {
        let separators: [Character] = ["•", "·"]
        guard text.contains(where: { separators.contains($0) }) else {
            // A lone "8.4K views" with nothing else has nothing to keep.
            return looksLikeViewCount(text) ? "" : text
        }
        let sep = text.contains("•") ? "•" : "·"
        let kept = text.components(separatedBy: sep)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !looksLikeViewCount($0) }
        return kept.joined(separator: " \(sep) ")
    }

    private static func looksLikeViewCount(_ part: String) -> Bool {
        let lowered = part.lowercased()
        return lowered.hasSuffix(" views") || lowered.hasSuffix(" view")
            || lowered == "views" || lowered == "view"
    }
}
