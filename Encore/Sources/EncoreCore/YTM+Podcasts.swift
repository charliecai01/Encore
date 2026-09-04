import Foundation

extension YTM {

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
}
