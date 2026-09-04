import Foundation

/// Parsers that turn raw InnerTube JSON into app models. These intentionally
/// traverse loosely (recursive key search) so minor YouTube layout changes
/// degrade gracefully instead of breaking pages outright.
public enum P {
    static let shelfRendererKeys = [
        "musicCarouselShelfRenderer",
        "musicShelfRenderer",
        "gridRenderer",
        "musicPlaylistShelfRenderer",
    ]

    /// Walk the tree in document order, yielding top-level shelf renderers
    /// without descending into them (avoids double-counting nested items).
    static func collectRenderers(_ v: JSONValue) -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = []
        func walk(_ node: JSONValue) {
            switch node {
            case .object(let dict):
                for key in shelfRendererKeys {
                    if let r = dict[key] {
                        out.append((key, r))
                        return
                    }
                }
                // Unfiltered search wraps each result in a bare itemSectionRenderer
                // with no shelf inside; emit those as pseudo-shelves.
                if let section = dict["itemSectionRenderer"] {
                    let wrapsShelf = shelfRendererKeys.contains { section.findFirst($0) != nil }
                    if !wrapsShelf, section.findFirst("musicResponsiveListItemRenderer") != nil {
                        out.append(("itemSectionRenderer", section))
                        return
                    }
                }
                for k in dict.keys.sorted() {
                    walk(dict[k]!)
                }
            case .array(let arr):
                for sub in arr { walk(sub) }
            default:
                break
            }
        }
        walk(v)
        return out
    }

    public static func thumbnailURL(in v: JSONValue) -> URL? {
        guard let thumbs = v.findFirst("thumbnails")?.array,
              let urlStr = thumbs.last?["url"].string else { return nil }
        return URL(string: urlStr)
    }

    public static func durationSeconds(fromText text: String) -> Int? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total = 0
        for part in parts {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    static func isDurationText(_ s: String) -> Bool {
        s.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    /// Pull artist/album refs out of a runs array (subtitle or byline).
    static func refs(fromRuns runsArr: [JSONValue]) -> (artists: [Ref], album: Ref?) {
        var artists: [Ref] = []
        var album: Ref?
        for run in runsArr {
            guard let text = run["text"].string else { continue }
            let browseId = run["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            guard let browseId else { continue }
            if browseId.hasPrefix("UC") || browseId.hasPrefix("FEmusic_library_privately_owned_artist") {
                artists.append(Ref(name: text, id: browseId))
            } else if browseId.hasPrefix("MPRE") {
                album = Ref(name: text, id: browseId)
            }
        }
        return (artists, album)
    }

    /// `refs(fromRuns:)` plus the shared "join artist names, or fall back to
    /// splitting subtitle text on ' • '" logic used by both the browse-row and
    /// queue-row parsers. `stripLabelsAndDuration` reproduces the browse-row
    /// fallback's extra filtering (drop "Song"/"Video" labels and duration
    /// text); pass false for the simpler queue-row fallback (first piece only).
    static func artistsAlbumAndLine(fromRuns runs: [JSONValue], fallbackText: String,
                                    stripLabelsAndDuration: Bool) -> (artists: [Ref], album: Ref?, line: String) {
        let (artists, album) = refs(fromRuns: runs)
        var line = artists.map(\.name).joined(separator: ", ")
        if line.isEmpty {
            if stripLabelsAndDuration {
                let pieces = fallbackText.components(separatedBy: " • ").filter { !$0.isEmpty && !isDurationText($0) }
                line = pieces.first { $0.lowercased() != "song" && $0.lowercased() != "video" } ?? fallbackText
            } else {
                line = fallbackText.components(separatedBy: " • ").first ?? fallbackText
            }
        }
        return (artists, album, line)
    }

    static func flexColumnRuns(_ r: JSONValue, _ index: Int) -> [JSONValue] {
        r["flexColumns"][index]["musicResponsiveListItemFlexColumnRenderer"]["text"].runs
    }

    static func flexColumnText(_ r: JSONValue, _ index: Int) -> String? {
        r["flexColumns"][index]["musicResponsiveListItemFlexColumnRenderer"]["text"].runsText
    }

    static func cardKind(forBrowseId browseId: String, pageType: String?) -> CardItem.Kind {
        if let pageType {
            if pageType.contains("PODCAST") { return .podcast }
            if pageType.contains("ALBUM") { return .album }
            if pageType.contains("ARTIST") || pageType.contains("USER_CHANNEL") { return .artist }
            if pageType.contains("PLAYLIST") { return .playlist }
        }
        if browseId.hasPrefix("MPSP") { return .podcast }  // podcast show
        if browseId.hasPrefix("MPRE") { return .album }
        if browseId.hasPrefix("MPLA") { return .artist }  // library artist page
        if browseId.hasPrefix("UC") { return .artist }
        if browseId.hasPrefix("VL") { return .playlist }
        return .unknown
    }
}
