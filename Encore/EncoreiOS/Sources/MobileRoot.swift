import SwiftUI
import EncoreCore

struct MobileRoot: View {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var auth = AuthManager.shared
    @StateObject private var nav = Nav.shared
    @StateObject private var library = LibraryStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $nav.selectedTab) {
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
            NowPlayingScreen()
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
        .task { await library.loadIfNeeded() }
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
            case .browse(let id): BrowseScreen(browseId: id)
            case .search(let q, let f): SearchScreen(initialQuery: q, initialFilter: f)
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
                HStack(spacing: 10) {
                    ArtworkView(url: player.current?.thumbnailURL, corner: 5)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.current?.title ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(player.current?.artistLine ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        if let t = player.current { player.toggleLike(t) }
                    } label: {
                        Image(systemName: player.current.map { player.likedIds.contains($0.videoId) } == true
                              ? "heart.fill" : "heart")
                            .font(.system(size: 16))
                            .foregroundStyle(player.current.map { player.likedIds.contains($0.videoId) } == true
                                             ? Theme.accent : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 30, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 2)
                        Rectangle().fill(Theme.accent)
                            .frame(width: max(0, geo.size.width * clock.progress), height: 2)
                    }
                }
                .frame(height: 2)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let url: URL?
    var corner: CGFloat = 8

    var body: some View {
        Color.clear.overlay {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Theme.card
                        Image(systemName: "music.note").foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
