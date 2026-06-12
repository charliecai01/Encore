import Foundation

/// Fallback synced-lyrics provider (lrclib.net, free and keyless) for when
/// YouTube has no timed lyrics for a track.
public enum LRCLib {
    public static func fetch(track: Track) async -> LyricsResult? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artists.first?.name ?? track.artistLine),
        ]
        if let album = track.album?.name {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration = track.durationSeconds {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        comps.queryItems = items

        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Encore/1.0 (https://github.com)", forHTTPHeaderField: "Lrclib-Client")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let json = JSONValue.parse(data)
        if let synced = json["syncedLyrics"].string, !synced.isEmpty,
           let lines = parseLRC(synced) {
            return LyricsResult(lines: lines, attribution: "Lyrics from LRCLIB", source: .lrclib)
        }
        if let plain = json["plainLyrics"].string, !plain.isEmpty {
            return LyricsResult(plain: plain, attribution: "Lyrics from LRCLIB", source: .lrclib)
        }
        return nil
    }

    static func parseLRC(_ lrc: String) -> [LyricLine]? {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var lines: [LyricLine] = []
        var id = 0
        for rawLine in lrc.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let textStart = last.range.location + last.range.length
            let text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let ms = Int((minutes * 60 + seconds) * 1000)
                lines.append(LyricLine(id: id, startMs: ms, text: text))
                id += 1
            }
        }
        guard lines.count >= 2 else { return nil }
        lines.sort { $0.startMs < $1.startMs }
        return lines.enumerated().map { LyricLine(id: $0.offset, startMs: $0.element.startMs, text: $0.element.text) }
    }
}
