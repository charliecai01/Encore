import Foundation

extension P {

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
                let plId = browseId.strippingPlaylistVLPrefix
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
            let plId = browseId.strippingPlaylistVLPrefix
            return CardItem(kind: .playlist, title: title, subtitle: subtitle,
                            thumbnailURL: thumb, browseId: browseId, playlistId: plId)
        }
        return CardItem(kind: kind, title: title, subtitle: subtitle,
                        thumbnailURL: thumb, browseId: browseId)
    }

    public static func continuationCards(from page: JSONValue) -> [CardItem] {
        continuationScope(of: page).findAll("musicTwoRowItemRenderer").compactMap { card(fromMTRIR: $0) }
    }
}
