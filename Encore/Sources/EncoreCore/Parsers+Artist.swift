import Foundation

extension P {

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

        // Order track shelves (e.g. "Top songs") by global play count, high → low.
        // YouTube's own order mixes in trending/recency, which isn't a strict
        // play-count ranking.
        func playCount(_ item: ShelfItem) -> Int {
            if case .track(let t) = item { return t.playCountValue ?? -1 }
            return -1
        }
        page.shelves = shelves(from: root).map { shelf in
            guard shelf.items.contains(where: { playCount($0) >= 0 }) else { return shelf }
            var s = shelf
            s.items = shelf.items.enumerated()
                .sorted { playCount($0.element) != playCount($1.element)
                    ? playCount($0.element) > playCount($1.element)
                    : $0.offset < $1.offset }
                .map(\.element)
            return s
        }

        // "Albums" / "Singles & EPs": latest release first (left-most).
        // YouTube already returns them this way in practice, but nothing
        // guarantees it — enforced here so it can't silently drift (Charlie,
        // 2026-08-20). Subtitles are "2026" for albums, "Single • 2024" for
        // singles/EPs, so pull the first 4-digit run rather than assuming format.
        func releaseYear(_ item: ShelfItem) -> Int {
            guard case .card(let c) = item,
                  let match = c.subtitle.range(of: #"\d{4}"#, options: .regularExpression)
            else { return -1 }
            return Int(c.subtitle[match]) ?? -1
        }
        page.shelves = page.shelves.map { shelf in
            guard shelf.title == "Albums" || shelf.title == "Singles & EPs" else { return shelf }
            var s = shelf
            s.items = shelf.items.enumerated()
                .sorted { releaseYear($0.element) != releaseYear($1.element)
                    ? releaseYear($0.element) > releaseYear($1.element)
                    : $0.offset < $1.offset }
                .map(\.element)
            return s
        }
        return page
    }
}
