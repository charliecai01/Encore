import Foundation

/// Orchestrates the lyrics providers. "Auto" tries everything in order of
/// synced-lyrics quality, keeping the best plain result as a fallback.
public final class LyricsService: @unchecked Sendable {
    public static let shared = LyricsService()

    public enum Provider: String, CaseIterable, Sendable {
        case auto, youtube, lrclib, netease, musixmatch, genius

        public var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .youtube: return "YT Music"
            case .lrclib: return "LRCLIB"
            case .netease: return "NetEase"
            case .musixmatch: return "Musixmatch"
            case .genius: return "Genius"
            }
        }
    }

    private let lock = NSLock()
    private var _preferred: Provider = .auto

    public var preferred: Provider {
        get { lock.lock(); defer { lock.unlock() }; return _preferred }
        set { lock.lock(); defer { lock.unlock() }; _preferred = newValue }
    }

    private init() {}

    /// Pass `knownBrowseId` when the caller already fetched the watch queue,
    /// to avoid a duplicate `next` request.
    public func lyrics(for track: Track, knownBrowseId: String?? = nil) async -> LyricsResult? {
        switch preferred {
        case .auto:
            return await auto(track, knownBrowseId: knownBrowseId)
        case .youtube:
            let browseId: String?
            if let knownBrowseId {
                browseId = knownBrowseId
            } else {
                browseId = await YTM.shared.lyricsBrowseId(for: track)
            }
            guard let browseId else { return nil }
            if let timed = await YTM.shared.youtubeTimedLyrics(browseId: browseId) { return timed }
            return await YTM.shared.youtubePlainLyrics(browseId: browseId)
        case .lrclib:
            return await LRCLib.fetch(track: track)
        case .netease:
            return await NetEase.fetch(track: track)
        case .musixmatch:
            return await Musixmatch.fetch(track: track)
        case .genius:
            return await Genius.fetch(track: track)
        }
    }

    private func auto(_ track: Track, knownBrowseId: String?? = nil) async -> LyricsResult? {
        var plainFallback: LyricsResult?
        let browseId: String?
        if let knownBrowseId {
            browseId = knownBrowseId
        } else {
            browseId = await YTM.shared.lyricsBrowseId(for: track)
        }

        if let browseId, let timed = await YTM.shared.youtubeTimedLyrics(browseId: browseId) {
            return timed
        }
        if let r = await LRCLib.fetch(track: track) {
            if r.lines != nil { return r }
            plainFallback = plainFallback ?? r
        }
        if let r = await NetEase.fetch(track: track), r.lines != nil {
            return r
        }
        if let r = await Musixmatch.fetch(track: track) {
            if r.lines != nil { return r }
            plainFallback = plainFallback ?? r
        }
        if let browseId, let plain = await YTM.shared.youtubePlainLyrics(browseId: browseId) {
            return plain
        }
        if let plainFallback {
            return plainFallback
        }
        return await Genius.fetch(track: track)
    }
}
