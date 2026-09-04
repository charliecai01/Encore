import Foundation

extension YTM {

    public func lyricsBrowseId(for track: Track) async -> String? {
        (try? await queue(videoId: track.videoId, playlistId: nil))?.lyricsBrowseId
    }

    /// The Android client returns line timing the web client doesn't.
    public func youtubeTimedLyrics(browseId: String) async -> LyricsResult? {
        guard let r = try? await net.post("browse", body: ["browseId": browseId], client: .androidMusic),
              let lines = P.timedLyrics(from: r) else { return nil }
        return LyricsResult(lines: lines, attribution: "Lyrics from YouTube Music", source: .youtube)
    }

    public func youtubePlainLyrics(browseId: String) async -> LyricsResult? {
        guard let r = try? await net.post("browse", body: ["browseId": browseId]),
              let plain = P.plainLyrics(from: r) else { return nil }
        return LyricsResult(plain: plain.text, attribution: plain.footer, source: .youtube)
    }
}
