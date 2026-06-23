import Foundation

/// One song's local play history.
public struct PlayRecord: Codable, Hashable {
    public var track: Track
    public var count: Int
    public var lastPlayedAt: Date

    public init(track: Track, count: Int, lastPlayedAt: Date) {
        self.track = track
        self.count = count
        self.lastPlayedAt = lastPlayedAt
    }
}

/// Local per-song play counts. YouTube Music exposes no personal play count, so
/// we track it client-side in UserDefaults and share it across both apps. A play
/// is recorded once a track has played past a short threshold (the engines call
/// `record`). Pure and unit-testable (override `store` in tests).
public enum PlayCounts {
    /// Overridable so tests can use a throwaway suite instead of `.standard`.
    public static var store: UserDefaults = .standard
    private static let key = "playCountsByVideoId"

    public static func all() -> [String: PlayRecord] {
        guard let data = store.data(forKey: key),
              let map = try? JSONDecoder().decode([String: PlayRecord].self, from: data) else { return [:] }
        return map
    }

    public static func count(for videoId: String) -> Int { all()[videoId]?.count ?? 0 }

    /// Record one play of `track`, incrementing its count and refreshing metadata.
    public static func record(_ track: Track) {
        guard !track.videoId.isEmpty else { return }
        var map = all()
        if var rec = map[track.videoId] {
            rec.count += 1
            rec.lastPlayedAt = Date()
            rec.track = track
            map[track.videoId] = rec
        } else {
            map[track.videoId] = PlayRecord(track: track, count: 1, lastPlayedAt: Date())
        }
        if let data = try? JSONEncoder().encode(map) { store.set(data, forKey: key) }
    }

    /// Songs ranked by play count (then most-recently played).
    public static func mostPlayed(limit: Int = 300) -> [PlayRecord] {
        Array(all().values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastPlayedAt > $1.lastPlayedAt }
            .prefix(limit))
    }

    public static func clear() { store.removeObject(forKey: key) }
}
