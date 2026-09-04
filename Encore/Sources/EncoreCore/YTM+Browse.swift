import Foundation

extension YTM {

    public func home() async throws -> [Shelf] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_home"])
        return P.shelves(from: r)
    }

    public func explore() async throws -> [Shelf] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_explore"])
        return P.shelves(from: r)
    }

    public func album(browseId: String) async throws -> CollectionPage {
        let r = try await net.post("browse", body: ["browseId": browseId])
        return P.collectionPage(from: r, isAlbum: true, albumBrowseId: browseId)
    }

    public func playlist(id: String) async throws -> CollectionPage {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let r = try await net.post("browse", body: ["browseId": browseId])
        var page = P.collectionPage(from: r, isAlbum: false)
        if page.playlistId == nil {
            page.playlistId = id.strippingPlaylistVLPrefix
        }
        // Some playlists are episode collections (e.g. the "New Episodes"
        // auto-playlist) whose items use the podcast renderer the regular track
        // parser skips — pull those in too so the list isn't empty. Gated on the
        // podcast feature so episodes don't leak into playlists when it's off.
        var episodes = PodcastFeature.enabled
            ? P.podcastEpisodes(from: r, showTitle: page.title, showThumb: page.thumbnailURL) : []
        let more = await continuationPages(after: r, maxPages: 40)
        for extra in more {
            page.tracks.append(contentsOf: P.continuationTracks(from: extra))
            if PodcastFeature.enabled {
                episodes.append(contentsOf: P.podcastEpisodes(from: extra, showTitle: page.title, showThumb: page.thumbnailURL))
            }
        }
        let known = Set(page.tracks.map(\.videoId))
        page.tracks.append(contentsOf: episodes.filter { !known.contains($0.videoId) })
        page.tracks = dedupe(page.tracks)
        return page
    }

    public func artist(browseId: String) async throws -> ArtistPage {
        let r = try await net.post("browse", body: ["browseId": browseId])
        return P.artistPage(from: r)
    }

    /// Generic browse page (e.g. library-artist MPLA pages): title + shelves.
    public func browsePage(browseId: String, params: String? = nil) async throws
        -> (title: String, shelves: [Shelf]) {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        let r = try await net.post("browse", body: body)
        let info = P.headerInfo(from: r)
        return (info.title, P.shelves(from: r))
    }

    /// YouTube Music's own mood/genre category pages. `params` selects the
    /// genre — probe `FEmusic_moods_and_genres` for the current values, they
    /// are opaque and can change.
    public enum Genre {
        public static let browseId = "FEmusic_moods_and_genres_category"
        /// "R&B & soul" (verified live 2026-08-04).
        public static let rnbParams = "ggMPOg1uX2JxQ2hxc2J5UFhR"
        public static let hipHopParams = "ggMPOg1uX01sVVAwVmNXcEIx"
        /// "Decades" — one shelf per decade, 2010s down to 1960s
        /// (verified live 2026-08-07).
        public static let decadesParams = "ggMPOg1uX3NjZllsNGVEMkZo"
        /// The decades we surface as "Classics": Charlie's taste here is Queen
        /// and Michael Jackson, whose peaks straddle these two.
        public static let classicDecades = ["1970s", "1980s"]

        /// Picks the classic-decade shelves out of a Decades category page and
        /// retitles them so they read as one section. Order follows
        /// `classicDecades`, not YouTube's (which runs newest-first).
        public static func classicShelves(from shelves: [Shelf]) -> [Shelf] {
            classicDecades.compactMap { decade in
                guard let match = shelves.first(where: { $0.title.contains(decade) }),
                      !match.items.isEmpty else { return nil }
                return Shelf(title: "Classics · \(match.title)",
                             items: match.items,
                             moreBrowseId: match.moreBrowseId)
            }
        }
    }

    /// The 1970s/1980s shelves from YouTube's "Decades" category.
    public func classics() async throws -> [Shelf] {
        Genre.classicShelves(from: try await genre(params: Genre.decadesParams))
    }

    /// Shelves for a genre category page (playlists/mixes YouTube curates).
    public func genre(params: String) async throws -> [Shelf] {
        try await browsePage(browseId: Genre.browseId, params: params).shelves
    }
}
