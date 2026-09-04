import Foundation

extension YTM {

    public func setLiked(videoId: String, liked: Bool) async throws {
        let endpoint = liked ? "like/like" : "like/removelike"
        _ = try await net.post(endpoint, body: ["target": ["videoId": videoId]], idempotent: false)
    }

    /// Save an album to (or remove it from) the library. YouTube models this as
    /// liking the album's audio playlist — the same `like/like` endpoint as a
    /// track, with a playlist target instead of a video one. Pass the id from
    /// `CollectionPage.libraryTargetPlaylistId`, which is the album's
    /// `OLAK5uy_…` playlist and not necessarily its `playlistId`.
    public func setAlbumSaved(playlistId: String, saved: Bool) async throws {
        let endpoint = saved ? "like/like" : "like/removelike"
        _ = try await net.post(endpoint, body: ["target": ["playlistId": playlistId]], idempotent: false)
    }

    private func succeeded(_ r: JSONValue) -> Bool {
        r["status"].string?.contains("SUCCEEDED") ?? false
    }

    /// Returns the new playlist's id.
    public func createPlaylist(title: String, privacy: String = "PRIVATE") async throws -> String? {
        let r = try await net.post("playlist/create", body: [
            "title": title,
            "privacyStatus": privacy,
        ], idempotent: false)
        return r["playlistId"].string
    }

    public func addToPlaylist(playlistId: String, videoId: String) async throws -> Bool {
        let pid = playlistId.strippingPlaylistVLPrefix
        let r = try await net.post("browse/edit_playlist", body: [
            "playlistId": pid,
            "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]],
        ], idempotent: false)
        return succeeded(r)
    }

    public func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String?) async throws -> Bool {
        let pid = playlistId.strippingPlaylistVLPrefix
        var action: [String: Any] = ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": videoId]
        if let setVideoId { action["setVideoId"] = setVideoId }
        let r = try await net.post("browse/edit_playlist", body: [
            "playlistId": pid,
            "actions": [action],
        ], idempotent: false)
        return succeeded(r)
    }

    /// Rename / re-describe / re-scope an owned playlist. Pass nil to leave a
    /// field unchanged. Privacy is "PUBLIC" | "PRIVATE" | "UNLISTED".
    public func editPlaylist(playlistId: String, title: String? = nil,
                             description: String? = nil, privacy: String? = nil) async throws -> Bool {
        let pid = playlistId.strippingPlaylistVLPrefix
        var actions: [[String: Any]] = []
        if let title { actions.append(["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]) }
        if let description {
            actions.append(["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": description])
        }
        if let privacy { actions.append(["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy]) }
        guard !actions.isEmpty else { return true }
        let r = try await net.post("browse/edit_playlist", body: ["playlistId": pid, "actions": actions], idempotent: false)
        return succeeded(r)
    }

    /// Delete an owned playlist. **Irreversible** — YouTube Music has no trash
    /// for playlists, so the UI must confirm before calling this.
    public func deletePlaylist(playlistId: String) async throws -> Bool {
        let pid = playlistId.strippingPlaylistVLPrefix
        let r = try await net.post("playlist/delete", body: ["playlistId": pid], idempotent: false)
        // A successful delete returns a command/status payload; treat an
        // explicit failure status as the only failure signal.
        if let status = r["status"].string { return status.contains("SUCCEEDED") }
        return r.exists
    }

    /// Flattened radio pools seeded from the given videoIds (deduped by the
    /// caller). Used to build a client-side "Discover" shelf.
    public func discoverPool(seeds: [String]) async -> [Track] {
        var pool: [Track] = []
        await withTaskGroup(of: [Track].self) { group in
            for seed in seeds.prefix(12) {
                group.addTask { (try? await self.radioQueue(for: seed))?.tracks ?? [] }
            }
            for await tracks in group { pool.append(contentsOf: tracks) }
        }
        return pool
    }
}
