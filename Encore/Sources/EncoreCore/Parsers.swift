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

    static func flexColumnRuns(_ r: JSONValue, _ index: Int) -> [JSONValue] {
        r["flexColumns"][index]["musicResponsiveListItemFlexColumnRenderer"]["text"].runs
    }

    static func flexColumnText(_ r: JSONValue, _ index: Int) -> String? {
        r["flexColumns"][index]["musicResponsiveListItemFlexColumnRenderer"]["text"].runsText
    }

    /// Parse a song row (musicResponsiveListItemRenderer).
    public static func track(fromMRLIR r: JSONValue,
                             fallbackThumb: URL? = nil,
                             fallbackAlbum: Ref? = nil) -> Track? {
        var videoId = r["playlistItemData"]["videoId"].string
        if videoId == nil {
            videoId = r["overlay"].findFirst("watchEndpoint")?["videoId"].string
        }
        if videoId == nil {
            videoId = r["flexColumns"][0].findFirst("watchEndpoint")?["videoId"].string
        }
        guard let videoId, !videoId.isEmpty else { return nil }

        let title = flexColumnText(r, 0) ?? "Unknown"

        // Subtitle columns: search results pack "Song • Artist • Album • 3:21"
        // into one column; playlist/album rows split artist and album.
        var allRuns: [JSONValue] = []
        let colCount = r["flexColumns"].array?.count ?? 0
        for i in 1..<max(colCount, 1) {
            allRuns.append(contentsOf: flexColumnRuns(r, i))
        }
        let (artists, albumRef) = refs(fromRuns: allRuns)

        var artistLine = artists.map(\.name).joined(separator: ", ")
        if artistLine.isEmpty {
            let col1Text = flexColumnText(r, 1) ?? ""
            let pieces = col1Text.components(separatedBy: " • ").filter { !$0.isEmpty && !isDurationText($0) }
            artistLine = pieces.first { $0.lowercased() != "song" && $0.lowercased() != "video" } ?? col1Text
        }

        var duration: Int?
        if let fixedText = r["fixedColumns"][0]["musicResponsiveListItemFixedColumnRenderer"]["text"].runsText,
           isDurationText(fixedText) {
            duration = durationSeconds(fromText: fixedText)
        }
        if duration == nil {
            for run in allRuns.reversed() {
                if let t = run["text"].string, isDurationText(t) {
                    duration = durationSeconds(fromText: t)
                    break
                }
            }
        }

        let thumb = thumbnailURL(in: r["thumbnail"]) ?? fallbackThumb
        let setVideoId = r["playlistItemData"]["playlistSetVideoId"].string

        // Podcast episodes carry a musicVideoType of …_PODCAST_EPISODE. Detect it
        // so the player shows episode controls (skip/speed) and the lock screen
        // gets skip — not next/prev — even when the episode lives in a playlist
        // (e.g. "New Episodes"), which otherwise parses it as a plain song.
        let isEpisode = r.findAll("musicVideoType").contains {
            let t = $0.string ?? ""
            return t.contains("EPISODE") || t.contains("PODCAST")
        }

        return Track(videoId: videoId, title: title, artists: artists, artistLine: artistLine,
                     album: albumRef ?? fallbackAlbum, durationSeconds: duration, thumbnailURL: thumb,
                     setVideoId: setVideoId, isEpisode: isEpisode)
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

    /// Parse a card (musicTwoRowItemRenderer) — albums, playlists, artists, mixes.
    public static func card(fromMTRIR r: JSONValue) -> CardItem? {
        guard let title = r["title"].runsText else { return nil }
        let subtitle = r["subtitle"].runsText ?? ""
        let thumb = thumbnailURL(in: r["thumbnailRenderer"])
        let nav = r["navigationEndpoint"]

        if let browseId = nav["browseEndpoint"]["browseId"].string {
            let pageType = nav["browseEndpoint"].findFirst("pageType")?.string
            let kind = cardKind(forBrowseId: browseId, pageType: pageType)
            switch kind {
            case .playlist:
                let plId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
                return CardItem(kind: .playlist, title: title, subtitle: subtitle,
                                thumbnailURL: thumb, browseId: browseId, playlistId: plId)
            case .album, .artist, .podcast:
                return CardItem(kind: kind, title: title, subtitle: subtitle,
                                thumbnailURL: thumb, browseId: browseId)
            default:
                return nil
            }
        }
        if let videoId = nav["watchEndpoint"]["videoId"].string {
            return CardItem(kind: .song, title: title, subtitle: subtitle,
                            thumbnailURL: thumb, videoId: videoId)
        }
        if let plId = nav["watchPlaylistEndpoint"]["playlistId"].string {
            return CardItem(kind: .station, title: title, subtitle: subtitle,
                            thumbnailURL: thumb, playlistId: plId)
        }
        return nil
    }

    /// Parse a browse row (musicResponsiveListItemRenderer that navigates, e.g. library artists).
    public static func card(fromMRLIR r: JSONValue) -> CardItem? {
        guard let browseId = r["navigationEndpoint"]["browseEndpoint"]["browseId"].string else { return nil }
        let title = flexColumnText(r, 0) ?? "Unknown"
        let subtitle = flexColumnText(r, 1) ?? ""
        let thumb = thumbnailURL(in: r["thumbnail"])
        let pageType = r["navigationEndpoint"]["browseEndpoint"].findFirst("pageType")?.string
        let kind = cardKind(forBrowseId: browseId, pageType: pageType)
        if kind == .playlist {
            let plId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
            return CardItem(kind: .playlist, title: title, subtitle: subtitle,
                            thumbnailURL: thumb, browseId: browseId, playlistId: plId)
        }
        return CardItem(kind: kind, title: title, subtitle: subtitle,
                        thumbnailURL: thumb, browseId: browseId)
    }

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
                let hasVideo = mrlir["playlistItemData"]["videoId"].exists
                    || mrlir["overlay"].findFirst("watchEndpoint") != nil
                if !hasVideo, let card = card(fromMRLIR: mrlir) {
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
            switch key {
            case "musicCarouselShelfRenderer":
                title = r["header"].findFirst("title")?.runsText ?? ""
            case "musicShelfRenderer":
                title = r["title"].runsText ?? ""
            case "gridRenderer":
                title = r["header"]["gridHeaderRenderer"]["title"].runsText ?? ""
            default:
                break
            }
            let items = shelfItems(fromContents: r["contents"].array ?? r["items"].array ?? [])
            if !items.isEmpty {
                out.append(Shelf(title: title, items: items))
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

    public static func headerInfo(from root: JSONValue) -> (title: String, subtitle: String,
                                                     second: String, description: String?,
                                                     thumb: URL?, playlistId: String?) {
        let header = root.findFirst("musicResponsiveHeaderRenderer")
            ?? root.findFirst("musicDetailHeaderRenderer")
            ?? root.findFirst("musicImmersiveHeaderRenderer")
            ?? .null

        let title = header["title"].runsText ?? ""
        var subtitleParts: [String] = []
        if let strapline = header["straplineTextOne"].runsText {
            subtitleParts.append(strapline)
        }
        if let sub = header["subtitle"].runsText {
            subtitleParts.append(sub)
        }
        let subtitle = subtitleParts.joined(separator: " • ")
        let second = header["secondSubtitle"].runsText ?? ""
        let description = header["description"].findFirst("description")?.runsText
            ?? header["description"].runsText
        let thumb = thumbnailURL(in: header)
        let playlistId = header.findFirst("watchEndpoint")?["playlistId"].string
            ?? header.findFirst("watchPlaylistEndpoint")?["playlistId"].string
        return (title, subtitle, second, description, thumb, playlistId)
    }

    public static func collectionPage(from root: JSONValue, isAlbum: Bool) -> CollectionPage {
        let info = headerInfo(from: root)
        var page = CollectionPage(title: info.title, subtitle: info.subtitle,
                                  secondSubtitle: info.second, description: info.description,
                                  thumbnailURL: info.thumb)

        let shelf = root.findFirst("musicPlaylistShelfRenderer") ?? root.findFirst("musicShelfRenderer") ?? .null
        page.playlistId = shelf["playlistId"].string ?? info.playlistId

        let fallbackAlbum = isAlbum ? Ref(name: info.title, id: nil) : nil
        let fallbackThumb = isAlbum ? info.thumb : nil
        page.tracks = (shelf["contents"].array ?? []).compactMap {
            track(fromMRLIR: $0["musicResponsiveListItemRenderer"],
                  fallbackThumb: fallbackThumb, fallbackAlbum: fallbackAlbum)
        }
        return page
    }

    /// Continuation responses also carry suggestion/related sections; scope
    /// item extraction to the appended-items payload so those never leak in.
    static func continuationScope(of page: JSONValue) -> JSONValue {
        page.findFirst("onResponseReceivedActions")
            ?? page.findFirst("continuationContents")
            ?? page
    }

    /// Extract additional tracks from a continuation response page.
    public static func continuationTracks(from page: JSONValue,
                                          fallbackThumb: URL? = nil,
                                          fallbackAlbum: Ref? = nil) -> [Track] {
        continuationScope(of: page).findAll("musicResponsiveListItemRenderer").compactMap {
            track(fromMRLIR: $0, fallbackThumb: fallbackThumb, fallbackAlbum: fallbackAlbum)
        }
    }

    public static func continuationCards(from page: JSONValue) -> [CardItem] {
        continuationScope(of: page).findAll("musicTwoRowItemRenderer").compactMap { card(fromMTRIR: $0) }
    }

    /// Podcast episodes (musicMultiRowListItemRenderer) → playable Tracks.
    public static func podcastEpisodes(from root: JSONValue, showTitle: String, showThumb: URL?) -> [Track] {
        continuationScope(of: root).findAll("musicMultiRowListItemRenderer").compactMap { r in
            guard let videoId = r.findFirst("watchEndpoint")?["videoId"].string
                ?? r.findFirst("videoId")?.string else { return nil }
            let title = r["title"].runsText ?? "Episode"
            let thumb = thumbnailURL(in: r) ?? showThumb
            // subtitle is the publish date ("6d ago"); description is the show
            // notes; duration comes as text ("1 hr 1 min").
            let date = r["subtitle"].runsText
            let details = r["description"].runsText
            let durSeconds = r.findFirst("musicPlaybackProgressRenderer")?["durationText"].runsText
                .flatMap(parsePodcastDuration)
            return Track(videoId: videoId, title: title, artists: [],
                         artistLine: showTitle, album: nil,
                         durationSeconds: durSeconds, thumbnailURL: thumb,
                         isEpisode: true, dateText: date, details: details)
        }
    }

    /// Parse a podcast duration label like "1 hr 1 min", "32 min", "45 sec".
    static func parsePodcastDuration(_ text: String) -> Int? {
        let lower = text.lowercased() as NSString
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)"#) else { return nil }
        var total = 0, matched = false
        regex.enumerateMatches(in: lower as String, range: NSRange(location: 0, length: lower.length)) { m, _, _ in
            guard let m, let n = Int(lower.substring(with: m.range(at: 1))) else { return }
            let unit = lower.substring(with: m.range(at: 2))
            matched = true
            if unit.hasPrefix("h") { total += n * 3600 }
            else if unit.hasPrefix("m") { total += n * 60 }
            else { total += n }
        }
        return matched ? total : nil
    }

    /// Find the next continuation token, preferring tokens that belong to the
    /// track list (signed-in playlists also carry a suggestions continuation).
    public static func continuationToken(in page: JSONValue) -> String? {
        for scopeKey in ["musicPlaylistShelfRenderer", "musicShelfRenderer",
                         "onResponseReceivedActions", "continuationContents", "gridRenderer"] {
            guard let scope = page.findFirst(scopeKey) else { continue }
            if let token = scope.findFirst("continuationItemRenderer")?["continuationEndpoint"]["continuationCommand"]["token"].string {
                return token
            }
            if let token = scope.findFirst("nextContinuationData")?["continuation"].string {
                return token
            }
        }
        if let token = page.findFirst("continuationItemRenderer")?["continuationEndpoint"]["continuationCommand"]["token"].string {
            return token
        }
        return page.findFirst("nextContinuationData")?["continuation"].string
    }

    public static func artistPage(from root: JSONValue) -> ArtistPage {
        let header = root.findFirst("musicImmersiveHeaderRenderer")
            ?? root.findFirst("musicVisualHeaderRenderer")
            ?? root.findFirst("musicResponsiveHeaderRenderer")
            ?? .null

        var page = ArtistPage()
        page.name = header["title"].runsText ?? ""
        page.description = header["description"].runsText
            ?? header["description"].findFirst("description")?.runsText
        page.heroURL = thumbnailURL(in: header)

        if let play = header["playButton"].findFirst("watchEndpoint") {
            page.shuffleVideoId = play["videoId"].string
            page.shufflePlaylistId = play["playlistId"].string
        }
        if let radio = header["startRadioButton"].findFirst("watchEndpoint") {
            page.radioPlaylistId = radio["playlistId"].string
        } else if let radio = header["startRadioButton"].findFirst("watchPlaylistEndpoint") {
            page.radioPlaylistId = radio["playlistId"].string
        }

        page.shelves = shelves(from: root)
        return page
    }

    public static func queueResult(from root: JSONValue) -> QueueResult {
        var result = QueueResult()
        guard let panel = root.findFirst("playlistPanelRenderer") else { return result }

        var tracks: [Track] = []
        var currentIndex = 0
        for content in panel["contents"].array ?? [] {
            var r = content["playlistPanelVideoRenderer"]
            if !r.exists {
                r = content["playlistPanelVideoWrapperRenderer"]["primaryRenderer"]["playlistPanelVideoRenderer"]
            }
            guard r.exists else { continue }
            guard let videoId = r["videoId"].string
                ?? r["navigationEndpoint"]["watchEndpoint"]["videoId"].string else { continue }

            let title = r["title"].runsText ?? "Unknown"
            let bylineRuns = r["longBylineText"].runs
            let (artists, album) = refs(fromRuns: bylineRuns)
            var artistLine = artists.map(\.name).joined(separator: ", ")
            if artistLine.isEmpty {
                let byline = r["longBylineText"].runsText ?? ""
                artistLine = byline.components(separatedBy: " • ").first ?? byline
            }
            var duration: Int?
            if let lt = r["lengthText"].runsText {
                duration = durationSeconds(fromText: lt)
            }
            let thumb = thumbnailURL(in: r["thumbnail"])

            if r["selected"].bool == true {
                currentIndex = tracks.count
                result.currentLikeStatus = r.findFirst("likeStatus")?.string
            }
            tracks.append(Track(videoId: videoId, title: title, artists: artists,
                                artistLine: artistLine, album: album,
                                durationSeconds: duration, thumbnailURL: thumb))
        }
        result.tracks = tracks
        result.currentIndex = currentIndex

        for tab in root.findAll("tabRenderer") {
            if let browseId = tab["endpoint"]["browseEndpoint"]["browseId"].string,
               browseId.hasPrefix("MPLYt") {
                result.lyricsBrowseId = browseId
                break
            }
        }
        return result
    }

    public static func timedLyrics(from root: JSONValue) -> [LyricLine]? {
        guard let data = root.findFirst("timedLyricsData")?.array else { return nil }
        var lines: [LyricLine] = []
        for (i, item) in data.enumerated() {
            guard let text = item["lyricLine"].string else { continue }
            let start = item["cueRange"]["startTimeMilliseconds"].intLike ?? 0
            lines.append(LyricLine(id: i, startMs: start, text: text))
        }
        return lines.count >= 2 ? lines : nil
    }

    public static func plainLyrics(from root: JSONValue) -> (text: String, footer: String?)? {
        guard let shelf = root.findFirst("musicDescriptionShelfRenderer"),
              let text = shelf["description"].runsText, !text.isEmpty else { return nil }
        return (text, shelf["footer"].runsText)
    }

    public static func suggestions(from root: JSONValue) -> [String] {
        root.findAll("searchSuggestionRenderer").compactMap {
            $0["suggestion"].runsText
        }
    }
}
