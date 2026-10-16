import AppIntents
import EncoreCore

// Siri / Shortcuts / Spotlight commands ("Play my favorites in Encore").
//
// This one file is compiled into BOTH apps: the macOS package target owns it
// and iOS/project.yml lists it as an extra source. PlayerEngine, LibraryStore
// and AuthManager have the same API on both platforms; the matching logic
// (which playlist a spoken name means) lives in EncoreCore.VoiceCommands.
//
// Transport commands ("next track", "pause") already reach Encore without
// any of this, through MPRemoteCommandCenter while Encore is the Now Playing
// app. Skip/Resume are here too so they work when another app holds Now
// Playing, or with Encore named explicitly.
//
// App Shortcuts are registered from build-time metadata (Metadata.appintents
// in the bundle). Xcode generates it for iOS; macOS is a plain SwiftPM build,
// so scripts/build_app.sh runs appintentsmetadataprocessor itself.

// Play intents bring the app forward on iOS (`openAppWhenRun`): playback
// runs in a WKWebView that is only reliable once the app's scene is up. The
// Mac has no such limit, so it plays without stealing focus. The metadata
// processor requires a literal there, hence the per-intent #if.

enum EncoreIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut, playlistNotFound, empty, nothingPlaying

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Encore first."
        case .playlistNotFound: "I couldn't find that playlist in your Encore library."
        case .empty: "There's nothing in there to play."
        case .nothingPlaying: "Nothing is playing in Encore."
        }
    }
}

@MainActor
private enum IntentSupport {
    /// A cold launch from Siri can run the intent before the scene's
    /// `AuthManager.bootstrap()`; without the cookie every API call is
    /// signed-out.
    static func ensureSignedIn() async throws {
        if !AuthManager.shared.isSignedIn { await AuthManager.shared.refresh() }
        guard AuthManager.shared.isSignedIn else { throw EncoreIntentError.signedOut }
    }

    static func playlists() async throws -> [CardItem] {
        try await ensureSignedIn()
        await LibraryStore.shared.loadIfNeeded()
        return LibraryStore.shared.playlists
    }

    static func shuffle(_ tracks: [Track], playlistId: String?) throws {
        let playable = PlayableQueue.build(tracks, startAt: 0).tracks
        guard !playable.isEmpty else { throw EncoreIntentError.empty }
        PlayerEngine.shared.playShuffled(playable, playlistId: playlistId)
    }

    static func playlistTracks(_ id: String) async throws -> [Track] {
        try await YTM.shared.playlist(id: id).tracks
    }
}

// MARK: - Playlist entity (the "\(playlist)" in "Play \(playlist) in Encore")

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init?(_ card: CardItem) {
        guard let id = card.playlistId ?? card.browseId?.strippingPlaylistVLPrefix else { return nil }
        self.id = id
        self.title = card.title
    }
}

struct PlaylistQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        let all = try await IntentSupport.playlists().compactMap(PlaylistEntity.init)
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let cards = try await IntentSupport.playlists()
        return VoiceCommands.bestPlaylistMatch(for: string, in: cards)
            .flatMap(PlaylistEntity.init).map { [$0] } ?? []
    }

    /// Also the vocabulary Siri listens for in parameterized phrases —
    /// refreshed via `updateAppShortcutParameters()` when the library loads.
    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await IntentSupport.playlists().compactMap(PlaylistEntity.init)
    }
}

// MARK: - Intents

struct PlayFavoritesIntent: AppIntent {
    static let title: LocalizedStringResource = "Play My Favorites"
    static let description = IntentDescription("Shuffles your Fav Songs playlist (or your liked songs if there isn't one).")
    #if os(iOS)
    static let openAppWhenRun = true
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        let playlists = try await IntentSupport.playlists()
        if let fav = VoiceCommands.favoritesPlaylist(in: playlists), let entity = PlaylistEntity(fav) {
            try IntentSupport.shuffle(try await IntentSupport.playlistTracks(entity.id), playlistId: entity.id)
        } else {
            try IntentSupport.shuffle(await LibraryStore.shared.songs(), playlistId: nil)
        }
        return .result()
    }
}

struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of your library playlists from the top.")
    #if os(iOS)
    static let openAppWhenRun = true
    #endif

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.ensureSignedIn()
        let (tracks, start) = PlayableQueue.build(try await IntentSupport.playlistTracks(playlist.id), startAt: 0)
        guard !tracks.isEmpty else { throw EncoreIntentError.empty }
        PlayerEngine.shared.playCollection(tracks, startAt: start, playlistId: playlist.id)
        return .result()
    }
}

struct ShufflePlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Playlist"
    static let description = IntentDescription("Shuffles one of your library playlists.")
    #if os(iOS)
    static let openAppWhenRun = true
    #endif

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.ensureSignedIn()
        try IntentSupport.shuffle(try await IntentSupport.playlistTracks(playlist.id), playlistId: playlist.id)
        return .result()
    }
}

struct ShuffleLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle My Library"
    static let description = IntentDescription("Shuffles every song in your library — liked songs plus all your playlists.")
    #if os(iOS)
    static let openAppWhenRun = true
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.ensureSignedIn()
        await LibraryStore.shared.loadIfNeeded()
        try IntentSupport.shuffle(await LibraryStore.shared.allKnownTracks(), playlistId: nil)
        return .result()
    }
}

struct LikeCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Current Song"
    static let description = IntentDescription("Likes the song playing in Encore on YouTube Music.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = PlayerEngine.shared
        guard let track = player.current else { throw EncoreIntentError.nothingPlaying }
        try await IntentSupport.ensureSignedIn()
        // Like only — never toggle an already-liked song back off by voice.
        if player.likedIds.contains(track.videoId) {
            return .result(dialog: "\(track.title) is already in your likes.")
        }
        player.toggleLike(track)
        return .result(dialog: "Liked \(track.title).")
    }
}

struct NowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription("Tells you the song playing in Encore.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let track = PlayerEngine.shared.current else { throw EncoreIntentError.nothingPlaying }
        let artist = track.artistLine
        return .result(dialog: artist.isEmpty ? "\(track.title)" : "\(track.title) by \(artist)")
    }
}

struct SkipTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next song in Encore.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard PlayerEngine.shared.current != nil else { throw EncoreIntentError.nothingPlaying }
        PlayerEngine.shared.next()
        return .result()
    }
}

struct ResumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume"
    static let description = IntentDescription("Resumes playback in Encore.")
    #if os(iOS)
    static let openAppWhenRun = true
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = PlayerEngine.shared
        guard player.current != nil else { throw EncoreIntentError.nothingPlaying }
        if !player.isPlaying { player.togglePlay() }
        return .result()
    }
}

// MARK: - Siri phrases

struct EncoreShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayFavoritesIntent(), phrases: [
            "Play my favorites in \(.applicationName)",
            "Play my favorite songs in \(.applicationName)",
            "Play my favorite song in \(.applicationName)",
            "Shuffle my favorites in \(.applicationName)",
            "Play my favorites on \(.applicationName)",
            "Play my favorite songs on \(.applicationName)",
        ], shortTitle: "Play Favorites", systemImageName: "heart.fill")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "Play \(\.$playlist) in \(.applicationName)",
            "Play \(\.$playlist) on \(.applicationName)",
            "Play my \(\.$playlist) playlist in \(.applicationName)",
            "Play a playlist in \(.applicationName)",
        ], shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: ShufflePlaylistIntent(), phrases: [
            "Shuffle \(\.$playlist) in \(.applicationName)",
            "Shuffle \(\.$playlist) on \(.applicationName)",
            "Shuffle a playlist in \(.applicationName)",
        ], shortTitle: "Shuffle Playlist", systemImageName: "shuffle")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: [
            "Shuffle my library in \(.applicationName)",
            "Shuffle my music in \(.applicationName)",
            "Shuffle all my songs in \(.applicationName)",
        ], shortTitle: "Shuffle Library", systemImageName: "shuffle.circle")
        AppShortcut(intent: LikeCurrentSongIntent(), phrases: [
            "Like this song in \(.applicationName)",
            "Like this song on \(.applicationName)",
            "I like this song in \(.applicationName)",
        ], shortTitle: "Like Song", systemImageName: "hand.thumbsup")
        AppShortcut(intent: NowPlayingIntent(), phrases: [
            "What's playing in \(.applicationName)",
            "What's playing on \(.applicationName)",
            "What song is this in \(.applicationName)",
        ], shortTitle: "What's Playing", systemImageName: "music.note")
        AppShortcut(intent: SkipTrackIntent(), phrases: [
            "Next track in \(.applicationName)",
            "Next song in \(.applicationName)",
            "Skip this song in \(.applicationName)",
        ], shortTitle: "Next Track", systemImageName: "forward.fill")
        AppShortcut(intent: ResumeIntent(), phrases: [
            "Resume \(.applicationName)",
            "Resume music in \(.applicationName)",
            "Continue playing in \(.applicationName)",
        ], shortTitle: "Resume", systemImageName: "play.fill")
    }
}
