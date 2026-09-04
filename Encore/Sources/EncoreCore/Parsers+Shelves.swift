import Foundation

extension P {

    public static func shelfItems(fromContents contents: [JSONValue],
                                  fallbackThumb: URL? = nil,
                                  fallbackAlbum: Ref? = nil) -> [ShelfItem] {
        contents.flatMap { c -> [ShelfItem] in
            // Top-result cards carry extra tracks in their own contents.
            if c["musicCardShelfRenderer"].exists {
                return shelfItems(fromContents: c["musicCardShelfRenderer"]["contents"].array ?? [])
            }
            return shelfItem(from: c, fallbackThumb: fallbackThumb, fallbackAlbum: fallbackAlbum)
                .map { [$0] } ?? []
        }
    }

    private static func shelfItem(from c: JSONValue,
                                  fallbackThumb: URL?,
                                  fallbackAlbum: Ref?) -> ShelfItem? {
        let mrlir = c["musicResponsiveListItemRenderer"]
            if mrlir.exists {
                // A row that NAVIGATES to a browse page is an album/artist/
                // playlist card — even though album rows ALSO carry a play
                // overlay. Testing the overlay first made every album search
                // result parse as a track, which dropped its browseId and left
                // album results unopenable. Real track rows carry
                // playlistItemData and no top-level browseEndpoint, so they
                // still fall through to track() below.
                let isTrackRow = mrlir["playlistItemData"]["videoId"].exists
                if !isTrackRow, let card = card(fromMRLIR: mrlir) {
                    return .card(card)
                }
                if let t = track(fromMRLIR: mrlir, fallbackThumb: fallbackThumb, fallbackAlbum: fallbackAlbum) {
                    return .track(t)
                }
                return nil
            }
            let mtrir = c["musicTwoRowItemRenderer"]
            if mtrir.exists, let card = card(fromMTRIR: mtrir) {
                return .card(card)
            }
            return nil
    }

    public static func shelves(from root: JSONValue) -> [Shelf] {
        var out: [Shelf] = []
        for (key, r) in collectRenderers(root) {
            var title = ""
            var moreBrowseId: String?
            switch key {
            case "musicCarouselShelfRenderer":
                title = r["header"].findFirst("title")?.runsText ?? ""
            case "musicShelfRenderer":
                title = r["title"].runsText ?? ""
                // The "more" link (e.g. an artist's full Top songs list) is the
                // shelf's bottomEndpoint, mirrored on the title's navigation.
                moreBrowseId = r["bottomEndpoint"]["browseEndpoint"]["browseId"].string
                    ?? r["title"].runs.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            case "gridRenderer":
                title = r["header"]["gridHeaderRenderer"]["title"].runsText ?? ""
            default:
                break
            }
            let items = shelfItems(fromContents: r["contents"].array ?? r["items"].array ?? [])
            if !items.isEmpty {
                out.append(Shelf(title: title, items: items, moreBrowseId: moreBrowseId))
            }
        }
        return out
    }

    public static func searchResults(from root: JSONValue) -> SearchResults {
        var results = SearchResults()
        if let card = root.findFirst("musicCardShelfRenderer") {
            let title = card["title"].runsText ?? ""
            let subtitle = card["subtitle"].runsText ?? ""
            let thumb = thumbnailURL(in: card["thumbnail"])
            let nav = card["title"].runs.first?["navigationEndpoint"] ?? .null
            if let videoId = nav["watchEndpoint"]["videoId"].string {
                results.top = .track(Track(videoId: videoId, title: title,
                                           artistLine: subtitle, thumbnailURL: thumb))
            } else if let browseId = nav["browseEndpoint"]["browseId"].string {
                let pageType = nav["browseEndpoint"].findFirst("pageType")?.string
                let kind = cardKind(forBrowseId: browseId, pageType: pageType)
                let plId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : nil
                results.top = .card(CardItem(kind: kind, title: title, subtitle: subtitle,
                                             thumbnailURL: thumb, browseId: browseId, playlistId: plId))
            }
        }
        // Flat-list search results arrive as many untitled single-item
        // shelves; fold them into one.
        var merged: [Shelf] = []
        var untitledItems: [ShelfItem] = []
        for shelf in shelves(from: root) {
            if shelf.title.isEmpty {
                untitledItems.append(contentsOf: shelf.items)
            } else {
                merged.append(shelf)
            }
        }
        if !untitledItems.isEmpty {
            merged.insert(Shelf(title: "Results", items: untitledItems), at: 0)
        }
        results.shelves = merged
        return results
    }

    public static func suggestions(from root: JSONValue) -> [String] {
        root.findAll("searchSuggestionRenderer").compactMap {
            $0["suggestion"].runsText
        }
    }
}
