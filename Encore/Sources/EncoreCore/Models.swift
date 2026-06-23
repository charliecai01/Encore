import Foundation

/// A named reference to an artist or album with an optional browse id.
public struct Ref: Hashable, Codable {
    public var name: String
    public var id: String?

    public init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }
}

public struct Track: Identifiable, Hashable, Codable {
    public var videoId: String
    public var title: String
    public var artists: [Ref]
    public var artistLine: String
    public var album: Ref?
    public var durationSeconds: Int?
    public var thumbnailURL: URL?
    /// Playlist-item id (playlistSetVideoId) — required to remove this entry
    /// from the playlist it was parsed out of.
    public var setVideoId: String?
    /// Podcast episode metadata (nil for music tracks).
    public var isEpisode: Bool
    /// Published/relative date text for episodes, e.g. "6d ago".
    public var dateText: String?
    /// Episode description / show notes.
    public var details: String?
    /// Global play-count label from YouTube, e.g. "102M plays" (nil when the
    /// source — artist Top songs, song search — doesn't provide one).
    public var playsText: String?

    public var id: String { videoId }

    public init(videoId: String, title: String, artists: [Ref] = [], artistLine: String = "",
                album: Ref? = nil, durationSeconds: Int? = nil, thumbnailURL: URL? = nil,
                setVideoId: String? = nil, isEpisode: Bool = false,
                dateText: String? = nil, details: String? = nil, playsText: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.artistLine = artistLine.isEmpty ? artists.map(\.name).joined(separator: ", ") : artistLine
        self.album = album
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.setVideoId = setVideoId
        self.isEpisode = isEpisode
        self.dateText = dateText
        self.details = details
        self.playsText = playsText
    }

    // Tolerant decoder so older cached payloads (without the episode fields)
    // still decode instead of dropping the whole cache.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        artists = (try? c.decode([Ref].self, forKey: .artists)) ?? []
        artistLine = (try? c.decode(String.self, forKey: .artistLine)) ?? ""
        album = try? c.decode(Ref.self, forKey: .album)
        durationSeconds = try? c.decode(Int.self, forKey: .durationSeconds)
        thumbnailURL = try? c.decode(URL.self, forKey: .thumbnailURL)
        setVideoId = try? c.decode(String.self, forKey: .setVideoId)
        isEpisode = (try? c.decode(Bool.self, forKey: .isEpisode)) ?? false
        dateText = try? c.decode(String.self, forKey: .dateText)
        details = try? c.decode(String.self, forKey: .details)
        playsText = try? c.decode(String.self, forKey: .playsText)
    }

    public var durationText: String {
        guard let s = durationSeconds else { return "" }
        return Track.format(seconds: s)
    }

    /// Podcast-style length, e.g. "1 hr 1 min" / "32 min".
    public var lengthText: String {
        guard let s = durationSeconds, s > 0 else { return "" }
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) hr \(m) min" : "\(h) hr" }
        if m > 0 { return "\(m) min" }
        return "\(s) sec"
    }

    public static func format(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// High-resolution artwork suitable for the now-playing screen.
    public var artworkURL: URL? {
        Artwork.upscale(thumbnailURL, to: 544)
    }

    /// Public YouTube Music link to this song — used for sharing / copying.
    public var shareURL: URL? {
        guard !videoId.isEmpty else { return nil }
        return URL(string: "https://music.youtube.com/watch?v=\(videoId)")
    }
}

public extension Track {
    /// Represent a track as a playable song card (for shelves/carousels).
    var asSongCard: CardItem {
        CardItem(kind: .song, title: title, subtitle: artistLine, thumbnailURL: thumbnailURL, videoId: videoId)
    }
}

public enum Artwork {
    /// Google-hosted thumbnails encode size in the URL; rewrite for a larger
    /// square. Handles both `=wN-hN-...` and `=sN-...` modifier styles.
    public static func upscale(_ url: URL?, to size: Int) -> URL? {
        guard let url else { return nil }
        var s = url.absoluteString
        guard s.contains("googleusercontent.com") || s.contains("ggpht.com") else { return url }
        let params = "=w\(size)-h\(size)-l90-rj"
        if let range = s.range(of: #"=(w\d+-h\d+|s\d+)[^=]*$"#, options: .regularExpression) {
            s.replaceSubrange(range, with: params)
        } else if !s.contains("=") {
            s += params
        } else {
            return url
        }
        return URL(string: s) ?? url
    }
}

public struct CardItem: Identifiable, Hashable, Codable {
    public enum Kind: Hashable, Codable {
        case album, playlist, artist, song, video, station, podcast, unknown
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var thumbnailURL: URL?
    public var browseId: String?
    public var playlistId: String?
    public var videoId: String?

    public init(kind: Kind, title: String, subtitle: String = "", thumbnailURL: URL? = nil,
                browseId: String? = nil, playlistId: String? = nil, videoId: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.thumbnailURL = thumbnailURL
        self.browseId = browseId
        self.playlistId = playlistId
        self.videoId = videoId
        self.id = browseId ?? playlistId ?? videoId ?? UUID().uuidString
    }
}

public enum ShelfItem: Hashable, Codable {
    case track(Track)
    case card(CardItem)
}

public struct Shelf: Identifiable, Hashable, Codable {
    public var id: String
    public var title: String
    public var items: [ShelfItem]
    /// browseId of the shelf's "more" link (e.g. an artist's full "Top songs"
    /// playlist), used to show a "Show all" button. nil when there's no more.
    public var moreBrowseId: String?

    public init(title: String, items: [ShelfItem], moreBrowseId: String? = nil) {
        self.id = UUID().uuidString
        self.title = title
        self.items = items
        self.moreBrowseId = moreBrowseId
    }

    public var isTrackShelf: Bool {
        items.contains {
            if case .track = $0 { return true }
            return false
        }
    }

    public var tracks: [Track] {
        items.compactMap {
            if case .track(let t) = $0 { return t }
            return nil
        }
    }
}

public struct SearchResults {
    public var top: ShelfItem?
    public var shelves: [Shelf]

    public init(top: ShelfItem? = nil, shelves: [Shelf] = []) {
        self.top = top
        self.shelves = shelves
    }
}

/// An album or playlist detail page.
public struct CollectionPage: Codable {
    public var title: String
    public var subtitle: String
    public var secondSubtitle: String
    public var description: String?
    public var thumbnailURL: URL?
    public var tracks: [Track]
    public var playlistId: String?

    public init(title: String = "", subtitle: String = "", secondSubtitle: String = "",
                description: String? = nil, thumbnailURL: URL? = nil,
                tracks: [Track] = [], playlistId: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.secondSubtitle = secondSubtitle
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.tracks = tracks
        self.playlistId = playlistId
    }
}

public struct ArtistPage {
    public var name: String
    public var description: String?
    public var heroURL: URL?
    public var shuffleVideoId: String?
    public var shufflePlaylistId: String?
    public var radioPlaylistId: String?
    public var shelves: [Shelf]

    public init(name: String = "", description: String? = nil, heroURL: URL? = nil,
                shuffleVideoId: String? = nil, shufflePlaylistId: String? = nil,
                radioPlaylistId: String? = nil, shelves: [Shelf] = []) {
        self.name = name
        self.description = description
        self.heroURL = heroURL
        self.shuffleVideoId = shuffleVideoId
        self.shufflePlaylistId = shufflePlaylistId
        self.radioPlaylistId = radioPlaylistId
        self.shelves = shelves
    }
}

public struct LyricLine: Identifiable, Hashable {
    public let id: Int
    public var startMs: Int
    public var text: String

    public init(id: Int, startMs: Int, text: String) {
        self.id = id
        self.startMs = startMs
        self.text = text
    }
}

public struct LyricsResult {
    public enum Source: String {
        case youtube
        case lrclib
        case netease
        case musixmatch
        case genius

        public var displayName: String {
            switch self {
            case .youtube: return "YouTube Music"
            case .lrclib: return "LRCLIB"
            case .netease: return "NetEase Music"
            case .musixmatch: return "Musixmatch"
            case .genius: return "Genius"
            }
        }
    }

    public var lines: [LyricLine]?
    public var plain: String?
    public var attribution: String?
    public var source: Source

    public init(lines: [LyricLine]? = nil, plain: String? = nil,
                attribution: String? = nil, source: Source) {
        self.lines = lines
        self.plain = plain
        self.attribution = attribution
        self.source = source
    }
}

public struct QueueResult {
    public var tracks: [Track]
    public var currentIndex: Int
    public var lyricsBrowseId: String?
    /// "LIKE" / "DISLIKE" / "INDIFFERENT" for the selected track, as reported
    /// by YouTube — the authoritative heart state.
    public var currentLikeStatus: String?

    public init(tracks: [Track] = [], currentIndex: Int = 0, lyricsBrowseId: String? = nil,
                currentLikeStatus: String? = nil) {
        self.tracks = tracks
        self.currentIndex = currentIndex
        self.lyricsBrowseId = lyricsBrowseId
        self.currentLikeStatus = currentLikeStatus
    }
}
