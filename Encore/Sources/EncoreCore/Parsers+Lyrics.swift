import Foundation

extension P {

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
}
