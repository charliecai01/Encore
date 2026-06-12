import SwiftUI
import EncoreCore

enum LibraryTab: String, CaseIterable, Hashable {
    case playlists = "Playlists"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case history = "History"

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .songs: return "heart"
        case .albums: return "square.stack"
        case .artists: return "music.microphone"
        case .history: return "clock"
        }
    }
}

enum Route: Hashable {
    case home
    case explore
    case library(LibraryTab)
    case search(String, YTM.SearchFilter?)
    case album(String)
    case playlist(String)
    case artist(String)
    case browse(String)
}

@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()

    @Published private(set) var current: Route = .home
    @Published var paletteShown = false
    @Published var showNewPlaylist = false
    /// Song to drop into the playlist created by the new-playlist sheet.
    var pendingPlaylistTrack: Track?

    private var backStack: [Route] = []
    private var forwardStack: [Route] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "lastRoute"),
           let route = Self.decode(saved) {
            current = route
        }
    }

    func go(_ route: Route) {
        guard route != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = route
        paletteShown = false
        persist()
    }

    func goBack() {
        guard let route = backStack.popLast() else { return }
        forwardStack.append(current)
        current = route
        persist()
    }

    func goForward() {
        guard let route = forwardStack.popLast() else { return }
        backStack.append(current)
        current = route
        persist()
    }

    /// Route an artist reference to whatever can actually display it: real
    /// channels get the artist page, library-only references get the generic
    /// browse page, and anything else falls back to an artist search.
    func goArtist(id: String?, name: String) {
        if let id {
            if id.hasPrefix("MPLA") {
                go(.artist(String(id.dropFirst(4))))
                return
            }
            if id.hasPrefix("UC") {
                go(.artist(id))
                return
            }
            if id.hasPrefix("FE") {
                go(.browse(id))
                return
            }
        }
        let query = name.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            go(.search(query, .artists))
        }
    }

    private func persist() {
        if let encoded = Self.encode(current) {
            UserDefaults.standard.set(encoded, forKey: "lastRoute")
        }
    }

    private static func encode(_ route: Route) -> String? {
        switch route {
        case .home: return "home"
        case .explore: return "explore"
        case .library(let tab): return "library|\(tab.rawValue)"
        case .album(let id): return "album|\(id)"
        case .playlist(let id): return "playlist|\(id)"
        case .artist(let id): return "artist|\(id)"
        case .browse(let id): return "browse|\(id)"
        case .search: return nil
        }
    }

    private static func decode(_ raw: String) -> Route? {
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard let kind = parts.first else { return nil }
        let arg = parts.count > 1 ? parts[1] : nil
        switch kind {
        case "home": return .home
        case "explore": return .explore
        case "library": return arg.flatMap { LibraryTab(rawValue: $0) }.map { .library($0) }
        case "album": return arg.map { .album($0) }
        case "playlist": return arg.map { .playlist($0) }
        case "artist": return arg.map { .artist($0) }
        case "browse": return arg.map { .browse($0) }
        default: return nil
        }
    }

    /// Route a card tap to the right page, or straight into playback for
    /// radio-style items that have no browse page.
    func open(_ item: CardItem) {
        switch item.kind {
        case .album:
            if let id = item.browseId { go(.album(id)) }
        case .artist:
            goArtist(id: item.browseId, name: item.title)
        case .playlist:
            if let id = item.playlistId, id.hasPrefix("RD") {
                PlayerEngine.shared.playStation(playlistId: id, title: item.title)
            } else if let id = item.playlistId {
                go(.playlist(id))
            }
        case .station:
            if let id = item.playlistId {
                PlayerEngine.shared.playStation(playlistId: id, title: item.title)
            }
        case .song, .video:
            if let videoId = item.videoId {
                let track = Track(videoId: videoId, title: item.title,
                                  artistLine: item.subtitle, thumbnailURL: item.thumbnailURL)
                PlayerEngine.shared.playRadio(from: track)
            }
        case .unknown:
            break
        }
    }
}
