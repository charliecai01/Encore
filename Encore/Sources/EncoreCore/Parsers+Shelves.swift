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
            var moreParams: String?
            switch key {
            case "musicCarouselShelfRenderer":
                title = r["header"].findFirst("title")?.runsText ?? ""
                // An artist's "Albums" / "Singles & EPs" carousel only holds
                // ~10 releases; its "More" link is the full discography grid.
                // Only discography links are kept — other carousels' "More"
                // targets aren't used and shouldn't light up "Show all".
                if let more = r["header"].findFirst("moreContentButton")?.findFirst("browseEndpoint")
                    ?? r["header"].findFirst("title")?.runs.first?["navigationEndpoint"]["browseEndpoint"],
                   let id = more["browseId"].string, id.hasPrefix("MPAD") {
                    moreBrowseId = id
                    moreParams = more["params"].string
                }
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
                out.append(Shelf(title: title, items: items, moreBrowseId: moreBrowseId,
                                 moreParams: moreParams))
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
                // Subtitle is "Video • Artist • 247M views • 5:10" — pull the
                // real artist refs and duration out of it, like a song row.
                let runs = card["subtitle"].runs
                let (artists, album, line) = artistsAlbumAndLine(
                    fromRuns: runs, fallbackText: subtitle, stripLabelsAndDuration: true)
                let duration = runs.compactMap { $0["text"].string }.last(where: isDurationText)
                    .flatMap(durationSeconds(fromText:))
                let mvTypes = card.findAll("musicVideoType").compactMap { $0.string }
                let isVideo = mvTypes.contains { $0.contains("MUSIC_VIDEO_TYPE") && !$0.contains("ATV") }
                results.top = .track(Track(videoId: videoId, title: title, artists: artists,
                                           artistLine: line, album: album, durationSeconds: duration,
                                           thumbnailURL: thumb, isVideo: isVideo))
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
        if let top = results.top, isDuplicate(top, of: merged.flatMap(\.items)) {
            results.top = nil
        }
        return results
    }

    /// The top hit is nearly always repeated as a result row — the same item,
    /// or (for a song) its music video above the audio track. Showing both
    /// reads as a duplicate first row (Charlie, 2026-10-17), so the top hit
    /// only stays when it's something the rows don't already have.
    static func isDuplicate(_ top: ShelfItem, of items: [ShelfItem]) -> Bool {
        switch top {
        case .card(let card):
            return items.contains { if case .card(let c) = $0 { return c.id == card.id }; return false }
        case .track(let track):
            // Artists by channel id first: the video credits "Jay Chou", the
            // song row "周杰倫" — same UC… id.
            let title = baseTitle(track.title)
            let ids = Set(track.artists.compactMap(\.id))
            let names = Set(track.artists.map { $0.name.matchNormalized })
            return items.contains {
                guard case .track(let t) = $0 else { return false }
                if t.videoId == track.videoId { return true }
                guard baseTitle(t.title) == title else { return false }
                return names.isEmpty || t.artists.contains {
                    ($0.id.map(ids.contains) ?? false) || names.contains($0.name.matchNormalized)
                }
            }
        }
    }

    /// "Anti-Hero (Official Music Video)" → "anti-hero", "晴天 - Sunny Day" →
    /// "晴天": drops trailing (…)/[…] qualifiers and a " - …" subtitle so a
    /// video and its song compare equal.
    static func baseTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+[-–—]\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).matchNormalized
    }

    public static func suggestions(from root: JSONValue) -> [String] {
        root.findAll("searchSuggestionRenderer").compactMap {
            $0["suggestion"].runsText
        }
    }
}
