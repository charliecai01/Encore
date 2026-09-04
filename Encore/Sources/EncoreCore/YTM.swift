import Foundation

/// High-level YouTube Music API used by the app.
public final class YTM: @unchecked Sendable {
    public static let shared = YTM()
    let net = InnerTube.shared

    public var isAuthenticated: Bool { net.isAuthenticated }

    private init() {}

    public enum SearchFilter: String, CaseIterable, Hashable {
        case songs, videos, albums, artists, playlists

        public var title: String { rawValue.capitalized }

        var params: String {
            switch self {
            case .songs: return "EgWKAQIIAWoMEA4QChADEAQQCRAF"
            case .videos: return "EgWKAQIQAWoMEA4QChADEAQQCRAF"
            case .albums: return "EgWKAQIYAWoMEA4QChADEAQQCRAF"
            case .artists: return "EgWKAQIgAWoMEA4QChADEAQQCRAF"
            case .playlists: return "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU%3D"
            }
        }
    }


    // MARK: - Continuations (shared by the Browse/Podcasts/Library extensions)

    /// Fetch follow-up pages for list responses; supports both the modern
    /// token style and the legacy ctoken style. Failures end pagination quietly.
    func continuationPages(after first: JSONValue, maxPages: Int) async -> [JSONValue] {
        var pages: [JSONValue] = []
        var current = first
        for _ in 0..<maxPages {
            guard let token = P.continuationToken(in: current) else { break }
            var response = try? await net.post("browse", body: ["continuation": token])
            let hasItems = response.map {
                let scope = P.continuationScope(of: $0)
                return scope.findFirst("musicResponsiveListItemRenderer") != nil
                    || scope.findFirst("musicTwoRowItemRenderer") != nil
                    || scope.findFirst("musicMultiRowListItemRenderer") != nil
            } ?? false
            if !hasItems,
               let legacy = try? await net.post("browse", body: [:],
                                                query: ["ctoken": token, "continuation": token, "type": "next"]) {
                response = legacy
            }
            guard let response else { break }
            pages.append(response)
            current = response
        }
        return pages
    }

    func dedupe(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.videoId).inserted }
    }
}
