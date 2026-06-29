import SwiftUI
import AppKit
import ImageIO
import EncoreCore

/// Memory-cached, deduplicating image loader. Unlike AsyncImage it keeps
/// decoded thumbnails across view lifetimes — so scrolling a list never
/// re-downloads — downsamples each image to the size it's actually drawn at
/// (off the main thread), and sends the YouTube session cookie for artwork that
/// requires it (personalized mix covers).
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [NSString: Task<NSImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    /// Pixel size to decode for a view `points` wide on a `scale`x display,
    /// rounded up to a small set of buckets so minor layout changes (window
    /// resizing, hover scaling) don't trigger a re-decode.
    nonisolated static func bucket(points: CGFloat, scale: CGFloat) -> Int {
        let px = Double(points * max(scale, 1))
        let buckets: [Int] = [80, 160, 240, 360, 540, 800, 1200, 1600]
        return buckets.first { Double($0) >= px } ?? 2048
    }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(url.absoluteString)" as NSString
    }

    func cached(for url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    func image(for url: URL, maxPixel: Int) async -> NSImage? {
        let k = key(url, maxPixel)
        if let hit = cache.object(forKey: k) { return hit }
        if let task = inflight[k] { return await task.value }

        let task = Task<NSImage?, Never> { await Self.fetch(url, maxPixel: maxPixel) }
        inflight[k] = task
        let image = await task.value
        inflight[k] = nil

        if let image {
            cache.setObject(image, forKey: k,
                            cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    /// Downloads and downsamples off the main actor (`nonisolated` runs on the
    /// cooperative pool), so neither the network wait nor the JPEG decode ever
    /// blocks the UI thread.
    nonisolated private static func fetch(_ url: URL, maxPixel: Int) async -> NSImage? {
        var req = URLRequest(url: url)
        if let host = url.host, host.hasSuffix("youtube.com"),
           let cookies = InnerTube.shared.cookieHeader {
            req.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return downsample(data, maxPixel: maxPixel)
    }

    nonisolated private static func downsample(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return NSImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct RemoteImage: View {
    let url: URL?
    var showsPlaceholderIcon = true

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            let px = ImageCache.bucket(points: side, scale: displayScale)
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .task(id: "\(url?.absoluteString ?? "")|\(side >= 1 ? px : 0)") {
                    guard side >= 1 else { return }
                    await load(maxPixel: px)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
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
    }

    private func load(maxPixel: Int) async {
        guard let url else { image = nil; loadedURL = nil; return }
        if let hit = ImageCache.shared.cached(for: url, maxPixel: maxPixel) {
            image = hit
            loadedURL = url
            return
        }
        // A different item is reusing this view: drop the stale art so the
        // placeholder shows while loading. A size-only change keeps the old
        // image visible until the sharper one arrives.
        if loadedURL != url { image = nil }
        loadedURL = url
        let loaded = await ImageCache.shared.image(for: url, maxPixel: maxPixel)
        if loadedURL == url { image = loaded }
    }
}
