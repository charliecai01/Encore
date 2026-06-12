import Foundation
import EncoreCore

/// Simple JSON disk cache under Application Support — performance over
/// storage, per Charlie's preference.
enum DiskCache {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Encore", isDirectory: true)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name))
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

/// Cache of fetched pages so navigation renders instantly; views refresh
/// contents silently in the background after serving from here. Collection
/// pages (playlists/albums) persist to disk across launches.
@MainActor
final class PageCache {
    static let shared = PageCache()

    var collections: [String: CollectionPage] = [:] {
        didSet { persistSoon() }
    }
    var artists: [String: ArtistPage] = [:]
    var shelves: [String: [Shelf]] = [:]
    var browse: [String: (title: String, shelves: [Shelf])] = [:]

    private var persistTask: Task<Void, Never>?

    private init() {
        if let saved = DiskCache.load([String: CollectionPage].self, from: "collections.json") {
            collections = saved
        }
    }

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            DiskCache.save(self.collections, as: "collections.json")
        }
    }

    func clear() {
        collections.removeAll()
        artists.removeAll()
        shelves.removeAll()
        browse.removeAll()
        DiskCache.remove("collections.json")
        DiskCache.remove("library-tracks.json")
    }
}
