import SwiftUI
import EncoreCore

/// First tab, and the one the app opens on: Charlie's "Favorite Songs"
/// playlist, straight in with no navigation.
///
/// The playlist id isn't known at build time, so it's resolved from the
/// library once and remembered — after the first successful resolve the tab
/// renders instantly on launch instead of waiting on the network, which
/// matters because this is the first thing shown.
struct FavoritesScreen: View {
    @EnvironmentObject var auth: AuthManager

    private static let idKey = "favoritesPlaylistId"
    /// Matched case-insensitively against playlist titles.
    private static let preferredTitle = "Favorite Songs"

    @State private var playlistId: String? = UserDefaults.standard.string(forKey: idKey)
    @State private var resolving = false
    @State private var failed = false

    var body: some View {
        Group {
            if let playlistId {
                CollectionScreen(kind: .playlist(playlistId))
            } else if !auth.isSignedIn {
                message("Sign in to see your favorites.")
            } else if resolving {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                VStack(spacing: 12) {
                    message("Couldn't find a “\(Self.preferredTitle)” playlist.")
                    Button("Try Again") { Task { await resolve() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .background(Theme.bg)
        .task(id: auth.isSignedIn) {
            // Re-resolve on sign-in change; a remembered id from another
            // account would show the wrong playlist.
            if !auth.isSignedIn {
                playlistId = nil
                UserDefaults.standard.removeObject(forKey: Self.idKey)
                return
            }
            if playlistId == nil { await resolve() }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolve() async {
        resolving = true
        failed = false
        defer { resolving = false }
        let playlists = (try? await YTM.shared.libraryPlaylists()) ?? []
        guard !playlists.isEmpty else { failed = true; return }
        // Prefer the named playlist; otherwise the first real one — "Liked
        // Music" is an auto playlist and already has its own Home shortcut.
        let match = playlists.first { $0.title.localizedCaseInsensitiveContains(Self.preferredTitle) }
            ?? playlists.first { ($0.playlistId ?? "").isEmpty == false && $0.subtitle != "Auto playlist" }
        guard let id = match?.playlistId else { failed = true; return }
        UserDefaults.standard.set(id, forKey: Self.idKey)
        playlistId = id
    }
}
