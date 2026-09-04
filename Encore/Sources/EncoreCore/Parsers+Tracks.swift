import Foundation

extension P {

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
        let (artists, albumRef, artistLine) = artistsAlbumAndLine(
            fromRuns: allRuns, fallbackText: flexColumnText(r, 1) ?? "", stripLabelsAndDuration: true)

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
        let mvTypes = r.findAll("musicVideoType").compactMap { $0.string }
        let isEpisode = mvTypes.contains { $0.contains("EPISODE") || $0.contains("PODCAST") }
        // Anything with a non-ATV musicVideoType (OMV/UGC/official-source) is a
        // real music video; the iOS player swaps these for their audio
        // counterpart so they keep playing on lock. ATV "art tracks" are audio.
        let isVideo = !isEpisode && mvTypes.contains {
            $0.contains("MUSIC_VIDEO_TYPE") && !$0.contains("ATV")
        }

        // Global play count ("102M plays") when present — artist Top songs and
        // song-search rows carry it as a subtitle run, not a standard column.
        let playsText = r.findAll("text").compactMap(\.runsText).first {
            $0.range(of: #"^[\d][\d.,]*\s*[KMBkmb]?\s*plays?$"#, options: .regularExpression) != nil
        }

        // YouTube marks rows it won't play (removed / region-blocked / rights
        // pulled) with a GREY_OUT display policy — the same field its own web
        // UI dims the row with. Playing one only ever returns player error 150,
        // and a run of them reads as the player "jumping around", so carry the
        // flag through and let the apps refuse the tap.
        let isUnavailable = (r["musicItemRendererDisplayPolicy"].string ?? "").contains("GREY_OUT")

        // Thumbs-up state from the row's own menu. Only LIKE counts; the rest
        // (INDIFFERENT, DISLIKE) mean not liked. Absent => nil, "don't know".
        let isLiked = r.findAll("likeStatus").compactMap(\.string).first.map { $0 == "LIKE" }

        return Track(videoId: videoId, title: title, artists: artists, artistLine: artistLine,
                     album: albumRef ?? fallbackAlbum, durationSeconds: duration, thumbnailURL: thumb,
                     setVideoId: setVideoId, isEpisode: isEpisode, isVideo: isVideo, playsText: playsText,
                     isUnavailable: isUnavailable, isLiked: isLiked)
    }

    /// Extract additional tracks from a continuation response page.
    public static func continuationTracks(from page: JSONValue,
                                          fallbackThumb: URL? = nil,
                                          fallbackAlbum: Ref? = nil) -> [Track] {
        continuationScope(of: page).findAll("musicResponsiveListItemRenderer").compactMap {
            track(fromMRLIR: $0, fallbackThumb: fallbackThumb, fallbackAlbum: fallbackAlbum)
        }
    }
}
