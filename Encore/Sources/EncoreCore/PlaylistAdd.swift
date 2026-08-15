import Foundation

/// Guards against adding a song to a playlist that already has it — YouTube
/// itself allows the duplicate, so nothing stops it server-side (Charlie's
/// call, 2026-08-14: "if it already exists in fav songs, it cannot be added
/// again").
public enum PlaylistAdd {

    /// Identity used for the "already there?" test, beyond the videoId.
    ///
    /// The same song is often published under several videoIds (a studio cut,
    /// a "(Live)" version, a re-upload), and the app already displays those
    /// identically — titles are stripped of trailing parentheticals and
    /// normalized. So matching on videoId ALONE would happily create rows
    /// that look like exact duplicates. This key matches what the user sees.
    public static func identity(_ track: Track) -> String {
        let title = NativeNames.displayTitle(track.title).lowercased()
        let artist = CJK.toSimplified(track.artistLine.lowercased())
        return artist + "::" + title
    }

    public struct Split {
        /// Genuinely new — safe to add.
        public var toAdd: [Track]
        /// Already in the target playlist (or repeated within the batch).
        public var duplicates: [Track]
    }

    /// Splits `tracks` into the ones worth adding and the ones the playlist
    /// already has. Also collapses repeats WITHIN the batch, so selecting the
    /// same song twice adds it once.
    public static func split(_ tracks: [Track], existing: [Track]) -> Split {
        var seenIds = Set(existing.map(\.videoId))
        var seenKeys = Set(existing.map(identity))
        var toAdd: [Track] = []
        var duplicates: [Track] = []
        for track in tracks {
            let key = identity(track)
            if seenIds.contains(track.videoId) || seenKeys.contains(key) {
                duplicates.append(track)
            } else {
                seenIds.insert(track.videoId)
                seenKeys.insert(key)
                toAdd.append(track)
            }
        }
        return Split(toAdd: toAdd, duplicates: duplicates)
    }

    /// The message to show after an add attempt. Kept here so both apps say
    /// the same thing, and so "nothing happened" is never silent.
    public static func resultMessage(added: Int, duplicates: Int, failed: Int,
                                     playlistTitle: String) -> String {
        if added == 0, duplicates > 0, failed == 0 {
            return duplicates == 1
                ? "Already in \(playlistTitle)"
                : "All \(duplicates) are already in \(playlistTitle)"
        }
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added) to \(playlistTitle)") }
        if duplicates > 0 { parts.append("\(duplicates) already there") }
        if failed > 0 { parts.append("\(failed) couldn't be added") }
        if parts.isEmpty { return "Couldn't add — you can only edit your own playlists" }
        return parts.joined(separator: " · ")
    }
}
