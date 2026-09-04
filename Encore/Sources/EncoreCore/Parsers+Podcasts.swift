import Foundation

extension P {

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
}
