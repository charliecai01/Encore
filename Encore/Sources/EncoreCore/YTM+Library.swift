import Foundation

extension YTM {

    /// Auto-playlists hidden from every playlist list: "New Episodes" (RDPN)
    /// and "Episodes for Later" (SE) — episodes surface via the Home "New
    /// Podcast Episodes" shelf and the show pages instead — plus "Liked Music"
    /// (LM), which Charlie emptied on 2026-08-16 and no longer wants listed.
    /// Liking a song still works; only the auto-playlist row is gone.
    private static let hiddenAutoPlaylists: Set<String> = ["RDPN", "SE", "LM"]

    public func libraryPlaylists() async throws -> [CardItem] {
        let r = try await net.post("browse", body: ["browseId": "FEmusic_liked_playlists"])
        var cards = r.findAll("musicTwoRowItemRenderer").compactMap { P.card(fromMTRIR: $0) }
        for page in await continuationPages(after: r, maxPages: 3) {
            cards.append(contentsOf: P.continuationCards(from: page))
        }
        return cards.filter { card in
            let pid = card.playlistId
                ?? card.browseId.map(\.strippingPlaylistVLPrefix)
                ?? card.id
            return !Self.hiddenAutoPlaylists.contains(pid)
        }
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
}
