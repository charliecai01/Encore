import Foundation
import os

let lyricsBrowserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

/// NetEase Cloud Music — free keyless API with strong synced-lyrics coverage
/// (notably the Chinese catalog).
public enum NetEase {
    public static func fetch(track: Track) async -> LyricsResult? {
        let query = "\(track.title) \(track.artists.first?.name ?? track.artistLine)"
        var comps = URLComponents(string: "https://music.163.com/api/search/get")!
        comps.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let searchURL = comps.url else { return nil }
        var req = URLRequest(url: searchURL)
        req.setValue(lyricsBrowserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }

        let songs = JSONValue.parse(data)["result"]["songs"].array ?? []
        guard !songs.isEmpty else { return nil }

        // Prefer the duration-matched hit; fall back to the top result.
        var songId = songs.first?["id"].int
        if let wanted = track.durationSeconds {
            for song in songs {
                if let ms = song["duration"].int, abs(ms / 1000 - wanted) <= 4 {
                    songId = song["id"].int
                    break
                }
            }
        }
        guard let songId else { return nil }

        var lyricComps = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyricComps.queryItems = [
            URLQueryItem(name: "id", value: String(songId)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        guard let lyricURL = lyricComps.url else { return nil }
        var lyricReq = URLRequest(url: lyricURL)
        lyricReq.setValue(lyricsBrowserUA, forHTTPHeaderField: "User-Agent")
        lyricReq.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        guard let (lyricData, _) = try? await URLSession.shared.data(for: lyricReq) else { return nil }

        let lrc = JSONValue.parse(lyricData)["lrc"]["lyric"].string ?? ""
        guard !lrc.isEmpty, let lines = LRCLib.parseLRC(lrc) else { return nil }
        return LyricsResult(lines: lines, attribution: "Lyrics from NetEase Music", source: .netease)
    }
}

/// Musixmatch — unofficial desktop-app API (same one the pear-desktop plugin
/// uses). Token fetch is rate-limited and occasionally captcha'd; failures
/// just mean falling through to the next provider.
public enum Musixmatch {
    // Cached token + when it was fetched, behind an async-safe scoped lock.
    private static let tokenCache = OSAllocatedUnfairLock<(token: String?, fetchedAt: Date)>(
        initialState: (nil, .distantPast))

    private static func getToken() async -> String? {
        let (cached, fetchedAt) = tokenCache.withLock { $0 }
        if let cached, Date().timeIntervalSince(fetchedAt) < 540 { return cached }

        var comps = URLComponents(string: "https://apic-desktop.musixmatch.com/ws/1.1/token.get")!
        comps.queryItems = [URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(lyricsBrowserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("AWSELB=0; AWSELBCORS=0", forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let fresh = JSONValue.parse(data)["message"]["body"]["user_token"].string
        guard let fresh, !fresh.isEmpty, !fresh.contains("UpgradeOnly") else { return nil }
        tokenCache.withLock { $0 = (fresh, Date()) }
        return fresh
    }

    public static func fetch(track: Track) async -> LyricsResult? {
        guard let token = await getToken() else { return nil }
        var comps = URLComponents(string: "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get")!
        var items = [
            URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
            URLQueryItem(name: "usertoken", value: token),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynched"),
            URLQueryItem(name: "subtitle_format", value: "lrc"),
            URLQueryItem(name: "q_track", value: track.title),
            URLQueryItem(name: "q_artist", value: track.artists.first?.name ?? track.artistLine),
        ]
        if let duration = track.durationSeconds {
            items.append(URLQueryItem(name: "q_duration", value: String(duration)))
        }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(lyricsBrowserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("AWSELB=0; AWSELBCORS=0", forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }

        let body = JSONValue.parse(data)["message"]["body"]["macro_calls"]
        let subtitle = body["track.subtitles.get"]["message"]["body"]["subtitle_list"][0]["subtitle"]
        if let lrc = subtitle["subtitle_body"].string, !lrc.isEmpty,
           let lines = LRCLib.parseLRC(lrc) {
            return LyricsResult(lines: lines, attribution: "Lyrics from Musixmatch", source: .musixmatch)
        }
        let plain = body["track.lyrics.get"]["message"]["body"]["lyrics"]["lyrics_body"].string
        if let plain, !plain.isEmpty {
            return LyricsResult(plain: plain, attribution: "Lyrics from Musixmatch", source: .musixmatch)
        }
        return nil
    }
}

/// Genius — plain lyrics only, scraped from the public song page.
public enum Genius {
    public static func fetch(track: Track) async -> LyricsResult? {
        let query = "\(track.title) \(track.artists.first?.name ?? track.artistLine)"
        var comps = URLComponents(string: "https://genius.com/api/search/multi")!
        comps.queryItems = [
            URLQueryItem(name: "per_page", value: "1"),
            URLQueryItem(name: "q", value: query),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(lyricsBrowserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }

        var pageURL: URL?
        for section in JSONValue.parse(data)["response"]["sections"].array ?? [] {
            for hit in section["hits"].array ?? [] {
                if hit["type"].string == "song",
                   let path = hit["result"]["url"].string {
                    pageURL = URL(string: path)
                    break
                }
            }
            if pageURL != nil { break }
        }
        guard let pageURL else { return nil }

        var pageReq = URLRequest(url: pageURL)
        pageReq.setValue(lyricsBrowserUA, forHTTPHeaderField: "User-Agent")
        guard let (html, _) = try? await URLSession.shared.data(for: pageReq),
              let text = String(data: html, encoding: .utf8) else { return nil }

        let containerRegex = try! NSRegularExpression(
            pattern: #"<div data-lyrics-container="true"[^>]*>([\s\S]*?)</div>"#)
        let ns = text as NSString
        let matches = containerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var lyrics = matches.map { ns.substring(with: $0.range(at: 1)) }.joined(separator: "\n")
        lyrics = lyrics.replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
        lyrics = lyrics.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        lyrics = lyrics.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard lyrics.count > 40 else { return nil }
        return LyricsResult(plain: lyrics, attribution: "Lyrics from Genius", source: .genius)
    }
}
