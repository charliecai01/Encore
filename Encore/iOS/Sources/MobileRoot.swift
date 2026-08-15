import SwiftUI
import UIKit
import ImageIO
import EncoreCore

struct MobileRoot: View {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var auth = AuthManager.shared
    @StateObject private var nav = Nav.shared
    @StateObject private var library = LibraryStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $nav.selectedTab) {
                // Home is the minimal playlists + albums launcher. It replaced
                // both the old Home (the Favorite Songs playlist) and the old
                // Explore shelf feed, which is why there's no Explore tab.
                NavigationStack(path: $nav.homePath) {
                    HomeScreen().routeDestinations()
                }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

                NavigationStack(path: $nav.searchPath) {
                    SearchScreen().routeDestinations()
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)

                NavigationStack(path: $nav.libraryPath) {
                    LibraryScreen().routeDestinations()
                }
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag(2)
            }
            .tint(Theme.accent)

            if player.current != nil {
                MiniPlayer()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 49) // sit just above the tab bar
            }
        }
        .environmentObject(player)
        .environmentObject(auth)
        .environmentObject(nav)
        .environmentObject(library)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sheet(isPresented: $auth.showLogin) { LoginSheet().environmentObject(auth) }
        .fullScreenCover(isPresented: $player.showNowPlaying) {
            NowPlayingSwitcher()
                .environmentObject(player)
                .environmentObject(nav)
        }
        .overlay(alignment: .top) {
            if let toast = player.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.toast)
        .task {
            // Native artist names resolved in earlier sessions are on disk;
            // load them before the first render so they don't pop in.
            NativeNames.seedFromDisk()
            await library.loadIfNeeded()
        }
        // Hidden player web view, kept in the hierarchy so WebKit keeps audio alive.
        .background(PlayerWebHost().frame(width: 1, height: 1).opacity(0.01))
    }
}

extension View {
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id): CollectionScreen(kind: .album(id))
            case .playlist(let id): CollectionScreen(kind: .playlist(id))
            case .artist(let id): ArtistScreen(browseId: id)
            case .podcastShow(let id): PodcastScreen(browseId: id)
            case .browse(let id): BrowseScreen(browseId: id)
            case .search(let q, let f): SearchScreen(initialQuery: q, initialFilter: f)
            case .mostPlayed: MostPlayedScreen()
            }
        }
    }
}

struct PlayerWebHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let web = PlayerEngine.shared.webView
        web.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(web)
        // The podcast video view borrows the web view; it parks it back here.
        PlayerEngine.shared.parkContainer = container
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Mini player

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerEngine
    @ObservedObject private var clock = PlayerClock.shared

    var body: some View {
        Button {
            player.showNowPlaying = true
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ArtworkView(url: player.current?.thumbnailURL, corner: 6)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NativeNames.displayTitle(player.current?.title ?? ""))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(NativeNames.displayCached(player.current?.artistLine ?? ""))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        if let t = player.current { player.toggleLike(t) }
                    } label: {
                        Image(systemName: player.current.map { player.likedIds.contains($0.videoId) } == true
                              ? "heart.fill" : "heart")
                            .font(.system(size: 19))
                            .foregroundStyle(player.current.map { player.likedIds.contains($0.videoId) } == true
                                             ? Theme.accent : Theme.textSecondary)
                            .frame(width: 42, height: 48)
                    }
                    .buttonStyle(.plain)
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 46, height: 48)
                    }
                    .buttonStyle(.plain)
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 42, height: 48)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 3)
                        Rectangle().fill(Theme.accent)
                            .frame(width: max(0, geo.size.width * clock.progress), height: 3)
                    }
                }
                .frame(height: 3)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artwork

/// Memory-cached, deduplicating image loader. Unlike AsyncImage it keeps
/// decoded thumbnails across view lifetimes — so scrolling a list never
/// re-downloads — downsamples each image to the size it's actually drawn at
/// (off the main thread), and sends the YouTube session cookie for artwork that
/// requires it. Mirrors the macOS ImageCache.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [NSString: Task<UIImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    /// Pixel size to decode for a view `points` wide on a `scale`x display,
    /// rounded up to a small set of buckets so minor layout changes don't
    /// trigger a re-decode.
    nonisolated static func bucket(points: CGFloat, scale: CGFloat) -> Int {
        let px = Double(points * max(scale, 1))
        let buckets: [Int] = [80, 160, 240, 360, 540, 800, 1200, 1600]
        return buckets.first { Double($0) >= px } ?? 2048
    }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(url.absoluteString)" as NSString
    }

    func cached(for url: URL, maxPixel: Int) -> UIImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let k = key(url, maxPixel)
        if let hit = cache.object(forKey: k) { return hit }
        if let task = inflight[k] { return await task.value }

        let task = Task<UIImage?, Never> { await Self.fetch(url, maxPixel: maxPixel) }
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
    /// blocks the UI thread while scrolling.
    nonisolated private static func fetch(_ url: URL, maxPixel: Int) async -> UIImage? {
        var req = URLRequest(url: url)
        if let host = url.host, host.hasSuffix("youtube.com"),
           let cookies = InnerTube.shared.cookieHeader {
            req.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return downsample(data, maxPixel: maxPixel)
    }

    nonisolated private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }
}

struct RemoteImage: View {
    let url: URL?
    var showsPlaceholderIcon = true

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
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
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.card
                if showsPlaceholderIcon {
                    Image(systemName: "music.note")
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

struct ArtworkView: View {
    let url: URL?
    var corner: CGFloat = 8

    var body: some View {
        Color.clear
            .overlay { RemoteImage(url: url) }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
