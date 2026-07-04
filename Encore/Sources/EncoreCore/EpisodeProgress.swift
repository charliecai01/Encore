import Foundation

/// One episode's saved playback position.
public struct EpisodeProgressEntry: Codable, Equatable {
    public var position: Double   // seconds into the episode
    public var duration: Double   // duration known at save time (0 = unknown)
    public var updatedAt: Date

    public init(position: Double, duration: Double, updatedAt: Date = Date()) {
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

/// Local per-episode playback positions, so podcasts resume where you left off
/// (YouTube Music has no server-side episode position). Shared by both apps via
/// UserDefaults; pure and unit-testable (override `store` in tests).
public enum EpisodeProgress {
    /// Overridable so tests can use a throwaway suite instead of `.standard`.
    public static var store: UserDefaults = .standard
    private static let key = "episodeProgressById"
    /// Keep the map bounded; oldest entries fall off.
    static let maxEntries = 500

    public static func all() -> [String: EpisodeProgressEntry] {
        guard let data = store.data(forKey: key),
              let map = try? JSONDecoder().decode([String: EpisodeProgressEntry].self, from: data)
        else { return [:] }
        return map
    }

    public static func entry(for videoId: String) -> EpisodeProgressEntry? {
        all()[videoId]
    }

    /// Record the current position. Positions under 5s are ignored so opening
    /// an episode for a moment doesn't create a "partially played" state.
    public static func save(_ videoId: String, position: Double, duration: Double) {
        guard !videoId.isEmpty, position >= 5 else { return }
        var map = all()
        map[videoId] = EpisodeProgressEntry(position: position, duration: max(0, duration))
        if map.count > maxEntries {
            let byAge = map.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxEntries)
            map = Dictionary(uniqueKeysWithValues: Array(byAge))
        }
        if let data = try? JSONEncoder().encode(map) { store.set(data, forKey: key) }
    }

    public static func clear(_ videoId: String) {
        var map = all()
        guard map.removeValue(forKey: videoId) != nil else { return }
        if let data = try? JSONEncoder().encode(map) { store.set(data, forKey: key) }
    }

    /// Where to restart playback, or nil to start from the top: only when
    /// meaningfully into the episode (≥ 20s) and not effectively finished
    /// (within 20s of the end). Rewinds 5s for context, like Apple Podcasts.
    public static func resumePosition(for videoId: String) -> Double? {
        guard let e = entry(for: videoId), e.position >= 20 else { return nil }
        if e.duration > 0, e.position >= e.duration - 20 { return nil }
        return max(0, e.position - 5)
    }

    /// Listened fraction (0…1) for progress bars; nil when unknown or none.
    public static func fraction(for videoId: String) -> Double? {
        guard let e = entry(for: videoId), e.duration > 0, e.position > 0 else { return nil }
        return min(1, max(0, e.position / e.duration))
    }

    /// Seconds left to listen; nil when the duration isn't known.
    public static func remainingSeconds(for videoId: String) -> Double? {
        guard let e = entry(for: videoId), e.duration > 0 else { return nil }
        return max(0, e.duration - e.position)
    }
}
