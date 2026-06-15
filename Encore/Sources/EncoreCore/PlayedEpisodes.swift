import Foundation

/// Local "played" state for podcast episodes. YouTube Music exposes no writable
/// per-episode played flag, so we track it client-side in UserDefaults and share
/// it across both apps. Pure and unit-testable (override `store` in tests).
public enum PlayedEpisodes {
    /// Overridable so tests can use a throwaway suite instead of `.standard`.
    public static var store: UserDefaults = .standard
    private static let key = "playedEpisodeIds"

    public static func all() -> Set<String> {
        Set(store.stringArray(forKey: key) ?? [])
    }

    public static func isPlayed(_ id: String) -> Bool {
        all().contains(id)
    }

    public static func set(_ id: String, played: Bool) {
        var ids = all()
        if played { ids.insert(id) } else { ids.remove(id) }
        store.set(Array(ids), forKey: key)
    }

    public static func toggle(_ id: String) {
        set(id, played: !isPlayed(id))
    }
}
