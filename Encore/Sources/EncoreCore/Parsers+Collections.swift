import Foundation

extension P {

    public static func headerInfo(from root: JSONValue) -> (title: String, subtitle: String,
                                                     second: String, description: String?,
                                                     thumb: URL?, playlistId: String?,
                                                     artistRef: Ref?) {
        let header = root.findFirst("musicResponsiveHeaderRenderer")
            ?? root.findFirst("musicDetailHeaderRenderer")
            ?? root.findFirst("musicImmersiveHeaderRenderer")
            ?? .null

        let title = header["title"].runsText ?? ""
        var subtitleParts: [String] = []
        var artistRef: Ref?
        if let strapline = header["straplineTextOne"].runsText {
            subtitleParts.append(strapline)
            // The strapline artist name is itself a link to the artist's
            // channel on album pages — grab its browseId so a track with no
            // per-row artist of its own (implied by the album) still has
            // somewhere for "tap the artist name" to navigate to.
            if let browseId = header["straplineTextOne"].runs.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
               browseId.hasPrefix("UC") {
                artistRef = Ref(name: strapline, id: browseId)
            }
        }
        if let sub = header["subtitle"].runsText {
            subtitleParts.append(sub)
        }
        let subtitle = subtitleParts.joined(separator: " • ")
        let second = header["secondSubtitle"].runsText ?? ""
        let description = header["description"].findFirst("description")?.runsText
            ?? header["description"].runsText
        // Take the header's OWN `thumbnail` (the cover) explicitly. A plain
        // recursive search finds `straplineThumbnail` — the ARTIST's avatar —
        // first on any header that has an artist strapline, which showed a
        // promo photo instead of the album cover (and, since album tracks
        // inherit this, on every row and queue entry too).
        let thumb = thumbnailURL(in: header["thumbnail"]) ?? thumbnailURL(in: header)
        let playlistId = header.findFirst("watchEndpoint")?["playlistId"].string
            ?? header.findFirst("watchPlaylistEndpoint")?["playlistId"].string
        return (title, subtitle, second, description, thumb, playlistId, artistRef)
    }

    /// - Parameter albumBrowseId: the album's own browseId. Album rows don't
    ///   repeat the album name, so their `album` ref comes from `fallbackAlbum`
    ///   below — and without this it had a nil id, which is what made "tap the
    ///   song title in the player bar to open its album" silently do nothing
    ///   for anything played off an album page.
    public static func collectionPage(from root: JSONValue, isAlbum: Bool,
                                      albumBrowseId: String? = nil) -> CollectionPage {
        let info = headerInfo(from: root)
        var page = CollectionPage(title: info.title, subtitle: info.subtitle,
                                  secondSubtitle: info.second, description: info.description,
                                  thumbnailURL: info.thumb,
                                  headerArtistRef: isAlbum ? info.artistRef : nil)

        let shelf = root.findFirst("musicPlaylistShelfRenderer") ?? root.findFirst("musicShelfRenderer") ?? .null
        page.playlistId = shelf["playlistId"].string ?? info.playlistId

        // The album's own audio playlist (OLAK5uy_…) is what "save to library"
        // likes. Do NOT go looking for the header's toggle menu: an album page
        // carries ~11 "Save album to library" toggles, one per related-album
        // card, and picking one by text saves a DIFFERENT album (it put "Bad"
        // and "Stayin' Alive" in Charlie's library instead of HIStory). The
        // toggles also all read "Save…" regardless of what's already saved, so
        // they can't be trusted for state either — callers resolve that against
        // the library album list instead.
        page.libraryTargetPlaylistId = isAlbum ? page.playlistId : nil

        let fallbackAlbum = isAlbum ? Ref(name: info.title, id: albumBrowseId) : nil
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
}
