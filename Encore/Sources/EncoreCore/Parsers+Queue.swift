import Foundation

extension P {

    public static func queueResult(from root: JSONValue) -> QueueResult {
        var result = QueueResult()
        // Initial radio responses carry a `playlistPanelRenderer`; continuation
        // pages carry a `playlistPanelContinuation` with the same `contents`.
        guard let panel = root.findFirst("playlistPanelRenderer")
            ?? root.findFirst("playlistPanelContinuation") else { return result }

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
            let (artists, album, artistLine) = artistsAlbumAndLine(
                fromRuns: bylineRuns, fallbackText: r["longBylineText"].runsText ?? "", stripLabelsAndDuration: false)
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

        // Endless-radio cursor — present on the initial panel and on each
        // continuation page. `nextRadioContinuationData` is the radio-specific
        // token; fall back to the generic queue continuation.
        result.continuation = root.findFirst("nextRadioContinuationData")?["continuation"].string
            ?? root.findFirst("nextContinuationData")?["continuation"].string

        for tab in root.findAll("tabRenderer") {
            if let browseId = tab["endpoint"]["browseEndpoint"]["browseId"].string,
               browseId.hasPrefix("MPLYt") {
                result.lyricsBrowseId = browseId
                break
            }
        }
        return result
    }

    /// The audio ("song") counterpart videoId for a music video, from a watch
    /// (`next`) response. YouTube pairs a music video with its audio track in a
    /// `playlistPanelVideoWrapperRenderer`; find the wrapper holding `videoId`
    /// and return the other id in it. nil when there's no counterpart.
    public static func audioCounterpartId(from root: JSONValue, for videoId: String) -> String? {
        for wrapper in root.findAll("playlistPanelVideoWrapperRenderer") {
            let ids = wrapper.findAll("playlistPanelVideoRenderer").compactMap { $0["videoId"].string }
            guard ids.contains(videoId) else { continue }
            if let alt = ids.first(where: { $0 != videoId && !$0.isEmpty }) {
                return alt
            }
        }
        return nil
    }
}
