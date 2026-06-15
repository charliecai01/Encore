import SwiftUI
import AppKit
import EncoreCore

/// Memory-cached, deduplicating image loader. Unlike AsyncImage it retries
/// when views reappear and sends the YouTube session cookie for artwork that
/// requires it (personalized mix covers).
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inflight[url] {
            return await task.value
        }
        let task = Task<NSImage?, Never> {
            var req = URLRequest(url: url)
            if let host = url.host, host.hasSuffix("youtube.com"),
               let cookies = InnerTube.shared.cookieHeader {
                req.setValue(cookies, forHTTPHeaderField: "Cookie")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            return image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }
}

struct RemoteImage: View {
    let url: URL?
    var showsPlaceholderIcon = true

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.card
                if showsPlaceholderIcon {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageCache.shared.cached(for: url) {
                image = hit
                return
            }
            image = nil
            image = await ImageCache.shared.image(for: url)
        }
    }
}
