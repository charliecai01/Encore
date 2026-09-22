import Foundation

/// Simple JSON disk cache under Application Support — performance over
/// storage, per Charlie's preference. Shared by both platforms' `PageCache`.
public enum DiskCache {
    public static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Encore", isDirectory: true)
    }

    public static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else {
            Log.library.error("DiskCache: failed to encode \(name)")
            return
        }
        do {
            try data.write(to: dir.appendingPathComponent(name))
        } catch {
            Log.library.error("DiskCache: failed to write \(name): \(error.localizedDescription)")
        }
    }

    public static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // The file exists (unlike a cold-launch miss above) but didn't
            // decode — usually a schema change. Worth knowing about, since the
            // caller silently falls back to an empty/live fetch either way.
            Log.library.error("DiskCache: \(name) exists but failed to decode: \(error.localizedDescription)")
            return nil
        }
    }

    public static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}
