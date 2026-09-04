import Foundation
import EncoreCore

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
