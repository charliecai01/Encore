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

    public var id: String { videoId }

    public init(videoId: String, title: String, artists: [Ref] = [], artistLine: String = "",
                album: Ref? = nil, durationSeconds: Int? = nil, thumbnailURL: URL? = nil,
                setVideoId: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.artistLine = artistLine.isEmpty ? artists.map(\.name).joined(separator: ", ") : artistLine
        self.album = album
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.setVideoId = setVideoId
    }

    public var durationText: String {
        guard let s = durationSeconds else { return "" }
        return Track.format(seconds: s)
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

public struct CardItem: Identifiable, Hashable {
    public enum Kind: Hashable {
        case album, playlist, artist, song, video, station, unknown
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

public enum ShelfItem: Hashable {
    case track(Track)
    case card(CardItem)
}

public struct Shelf: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var items: [ShelfItem]

    public init(title: String, items: [ShelfItem]) {
        self.id = UUID().uuidString
        self.title = title
        self.items = items
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
