import Foundation

/// High-level YouTube Music API used by the app.
public final class YTM: @unchecked Sendable {
    public static let shared = YTM()
    private let net = InnerTube.shared

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

    // MARK: - Browse

    public func home() async throws -> [Shelf] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_home"])
        return P.shelves(from: r)
    }

    public func explore() async throws -> [Shelf] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_explore"])
        return P.shelves(from: r)
    }

    // MARK: - Podcasts

    public func podcasts() async throws -> [Shelf] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_podcasts"])
        return P.shelves(from: r)
    }

    /// Podcasts screen: the user's own subscribed shows + saved episodes first,
    /// then the discover feed.
    public func podcastsHome() async throws -> [Shelf] {
        async let libTask: [CardItem] = (try? await libraryPodcasts()) ?? []
        async let discoverTask: [Shelf] = (try? await podcasts()) ?? []
        let lib = await libTask
        let discover = await discoverTask

        var shelves: [Shelf] = []
        if !lib.isEmpty {
            shelves.append(Shelf(title: "Your Podcasts", items: lib.map { .card($0) }))
        }
        shelves.append(contentsOf: discover)
        if shelves.isEmpty { throw InnerTubeError.notSignedIn }
        return shelves
    }

    /// A podcast show page: header + episodes (each a playable video).
    public func podcastShow(browseId: String) async throws -> CollectionPage {
        let r = try await net.post("browse", body: ["browseId": browseId])
        let info = P.headerInfo(from: r)
        var page = CollectionPage(title: info.title, subtitle: info.subtitle,
                                  secondSubtitle: info.second, description: info.description,
                                  thumbnailURL: info.thumb)
        page.tracks = P.podcastEpisodes(from: r, showTitle: info.title, showThumb: info.thumb)
        for extra in await continuationPages(after: r, maxPages: 10) {
            page.tracks.append(contentsOf: P.podcastEpisodes(from: extra, showTitle: info.title, showThumb: info.thumb))
        }
        page.tracks = dedupe(page.tracks)
        return page
    }

    public func libraryPodcasts() async throws -> [CardItem] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_library_non_music_audio_list"])
        func parse(_ page: JSONValue) -> [CardItem] {
            let twoRow = page.findAll("musicTwoRowItemRenderer").compactMap { P.card(fromMTRIR: $0) }
            let listRow = page.findAll("musicResponsiveListItemRenderer").compactMap { P.card(fromMRLIR: $0) }
            return twoRow + listRow
        }
        var cards = parse(r)
        for page in await continuationPages(after: r, maxPages: 4) {
            cards.append(contentsOf: parse(page))
        }
        // Keep podcast shows and episode collections; drop anything unrelated.
        var seen = Set<String>()
        return cards.filter { ($0.kind == .podcast || $0.kind == .playlist) && seen.insert($0.id).inserted }
    }

    public func album(browseId: String) async throws -> CollectionPage {
        let r = try await net.post("browse", body: ["browseId": browseId])
        return P.collectionPage(from: r, isAlbum: true)
    }

    public func playlist(id: String) async throws -> CollectionPage {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let r = try await net.post("browse", body: ["browseId": browseId])
        var page = P.collectionPage(from: r, isAlbum: false)
        if page.playlistId == nil {
            page.playlistId = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        }
        let more = await continuationPages(after: r, maxPages: 40)
        for extra in more {
            page.tracks.append(contentsOf: P.continuationTracks(from: extra))
        }
        page.tracks = dedupe(page.tracks)
        return page
    }

    public func artist(browseId: String) async throws -> ArtistPage {
        let r = try await net.post("browse", body: ["browseId": browseId])
        return P.artistPage(from: r)
    }

    /// Generic browse page (e.g. library-artist MPLA pages): title + shelves.
    public func browsePage(browseId: String) async throws -> (title: String, shelves: [Shelf]) {
        let r = try await net.post("browse", body: ["browseId": browseId])
        let info = P.headerInfo(from: r)
        return (info.title, P.shelves(from: r))
    }

    // MARK: - Search

    /// Searches the query as typed; for Simplified Chinese input, also
    /// searches the Traditional form and merges (Taiwanese artists are listed
    /// in Traditional and YouTube doesn't always bridge the scripts).
    public func search(_ query: String, filter: SearchFilter?) async throws -> SearchResults {
        guard let variant = CJK.toTraditional(query) else {
            return try await searchRaw(query, filter: filter)
        }
        async let primaryTask = searchRaw(query, filter: filter)
        async let variantTask = try? searchRaw(variant, filter: filter)
        let primary = try await primaryTask
        guard let secondary = await variantTask else { return primary }
        return merged(primary, secondary)
    }

    private func searchRaw(_ query: String, filter: SearchFilter?) async throws -> SearchResults {
        var body: [String: Any] = ["query": query]
        if let filter { body["params"] = filter.params }
        let r = try await net.post("search", body: body)
        return P.searchResults(from: r)
    }

    private func merged(_ a: SearchResults, _ b: SearchResults) -> SearchResults {
        var out = a
        if out.top == nil { out.top = b.top }

        var seen = Set<String>()
        func key(_ item: ShelfItem) -> String {
            switch item {
            case .track(let t): return "t:" + t.videoId
            case .card(let c): return "c:" + c.id
            }
        }
        for shelf in out.shelves {
            for item in shelf.items { seen.insert(key(item)) }
        }
        if let top = out.top { seen.insert(key(top)) }

        for shelf in b.shelves {
            let fresh = shelf.items.filter { seen.insert(key($0)).inserted }
            guard !fresh.isEmpty else { continue }
            if let idx = out.shelves.firstIndex(where: { $0.title == shelf.title }) {
                out.shelves[idx].items.append(contentsOf: fresh)
            } else {
                out.shelves.append(Shelf(title: shelf.title, items: fresh))
            }
        }
        return out
    }

    public func suggestions(_ input: String) async throws -> [String] {
        let r = try await net.post("music/get_search_suggestions", body: ["input": input])
        var results = P.suggestions(from: r)
        if let variant = CJK.toTraditional(input), !results.contains(variant) {
            results.insert(variant, at: 0)
        }
        return results
    }

    // MARK: - Library

    public func libraryPlaylists() async throws -> [CardItem] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_liked_playlists"])
        var cards = r.findAll("musicTwoRowItemRenderer").compactMap { P.card(fromMTRIR: $0) }
        for page in await continuationPages(after: r, maxPages: 3) {
            cards.append(contentsOf: P.continuationCards(from: page))
        }
        return cards
    }

    public func librarySongs() async throws -> [Track] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_liked_videos"])
        var tracks = P.continuationTracks(from: r)
        for page in await continuationPages(after: r, maxPages: 50) {
            tracks.append(contentsOf: P.continuationTracks(from: page))
        }
        return dedupe(tracks)
    }

    public func libraryAlbums() async throws -> [CardItem] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_liked_albums"])
        var cards = r.findAll("musicTwoRowItemRenderer").compactMap { P.card(fromMTRIR: $0) }
        for page in await continuationPages(after: r, maxPages: 3) {
            cards.append(contentsOf: P.continuationCards(from: page))
        }
        return cards
    }

    public func libraryArtists() async throws -> [CardItem] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_library_corpus_track_artists"])
        var cards = r.findAll("musicResponsiveListItemRenderer").compactMap { P.card(fromMRLIR: $0) }
        for page in await continuationPages(after: r, maxPages: 3) {
            cards.append(contentsOf: page.findAll("musicResponsiveListItemRenderer").compactMap { P.card(fromMRLIR: $0) })
        }
        return cards
    }

    public func history() async throws -> [Shelf] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_history"])
        return P.shelves(from: r)
    }

    // MARK: - Queue / radio

    public func queue(videoId: String?, playlistId: String?, params: String? = nil) async throws -> QueueResult {
        var body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        if let videoId { body["videoId"] = videoId }
        if let playlistId { body["playlistId"] = playlistId }
        if let params { body["params"] = params }
        let r = try await net.post("next", body: body)
        return P.queueResult(from: r)
    }

    public func radioQueue(for videoId: String) async throws -> QueueResult {
        try await queue(videoId: videoId, playlistId: "RDAMVM" + videoId)
    }

    // MARK: - Lyrics

    public func lyricsBrowseId(for track: Track) async -> String? {
        (try? await queue(videoId: track.videoId, playlistId: nil))?.lyricsBrowseId
    }

    /// The Android client returns line timing the web client doesn't.
    public func youtubeTimedLyrics(browseId: String) async -> LyricsResult? {
        guard let r = try? await net.post("browse", body: ["browseId": browseId], client: .androidMusic),
              let lines = P.timedLyrics(from: r) else { return nil }
        return LyricsResult(lines: lines, attribution: "Lyrics from YouTube Music", source: .youtube)
    }

    public func youtubePlainLyrics(browseId: String) async -> LyricsResult? {
        guard let r = try? await net.post("browse", body: ["browseId": browseId]),
              let plain = P.plainLyrics(from: r) else { return nil }
        return LyricsResult(plain: plain.text, attribution: plain.footer, source: .youtube)
    }

    // MARK: - Feedback

    public func setLiked(videoId: String, liked: Bool) async throws {
        let endpoint = liked ? "like/like" : "like/removelike"
        _ = try await net.post(endpoint, body: ["target": ["videoId": videoId]])
    }

    // MARK: - Playlist management

    /// Returns the new playlist's id.
    public func createPlaylist(title: String, privacy: String = "PRIVATE") async throws -> String? {
        let r = try await net.post("playlist/create", body: [
            "title": title,
            "privacyStatus": privacy,
        ])
        return r["playlistId"].string
    }

    public func addToPlaylist(playlistId: String, videoId: String) async throws -> Bool {
        let pid = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let r = try await net.post("browse/edit_playlist", body: [
            "playlistId": pid,
            "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]],
        ])
        return r["status"].string?.contains("SUCCEEDED") ?? false
    }

    public func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String?) async throws -> Bool {
        let pid = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        var action: [String: Any] = ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": videoId]
        if let setVideoId { action["setVideoId"] = setVideoId }
        let r = try await net.post("browse/edit_playlist", body: [
            "playlistId": pid,
            "actions": [action],
        ])
        return r["status"].string?.contains("SUCCEEDED") ?? false
    }

    // MARK: - Continuations

    /// Fetch follow-up pages for list responses; supports both the modern
    /// token style and the legacy ctoken style. Failures end pagination quietly.
    private func continuationPages(after first: JSONValue, maxPages: Int) async -> [JSONValue] {
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

    private func dedupe(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.videoId).inserted }
    }
}
