import SwiftUI
import EncoreCore

struct RootView: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: 224)
                    Rectangle()
                        .fill(Theme.stroke)
                        .frame(width: 1)
                    VStack(spacing: 0) {
                        TopBar()
                        ContentRouter()
                    }
                    .frame(maxWidth: .infinity)

                    // Up Next is pinned — always visible, no close control.
                    Rectangle()
                        .fill(Theme.stroke)
                        .frame(width: 1)
                    QueuePanel()
                        .frame(width: 300)
                }
                .frame(maxHeight: .infinity)

                PlayerBar(nowPlayingExpanded: $player.showNowPlaying)
            }

            if player.showNowPlaying {
                NowPlayingView(expanded: $player.showNowPlaying)
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }

            if nav.paletteShown {
                CommandPalette()
                    .zIndex(20)
            }

            if let toast = player.toast {
                ToastView(message: toast)
                    .padding(.bottom, 104)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(30)
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .bottomTrailing) {
            // The playback web view parks here at 2×2 px; it must stay in the
            // visible hierarchy or WebKit suspends media.
            PlayerWebHost()
                .frame(width: 2, height: 2)
                .opacity(0.02)
        }
        .animation(.spring(duration: 0.35), value: player.showNowPlaying)
        .animation(.easeInOut(duration: 0.2), value: player.toast)
        .sheet(isPresented: $auth.showLogin) {
            LoginSheet()
        }
        .sheet(isPresented: $player.showSiteSettings) {
            SiteSettingsSheet()
        }
        .sheet(isPresented: $nav.showNewPlaylist) {
            NewPlaylistSheet()
        }
    }
}

struct NewPlaylistSheet: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore

    @State private var name = ""
    @State private var privacy = "PRIVATE"
    @State private var creating = false
    @FocusState private var focused: Bool

    private let privacyOptions = [("PRIVATE", "Private"), ("UNLISTED", "Unlisted"), ("PUBLIC", "Public")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Playlist")
                .font(.headline)
            if let track = nav.pendingPlaylistTrack {
                Text("“\(track.title)” will be added")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { create() }
            Picker("Privacy", selection: $privacy) {
                ForEach(privacyOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Button("Cancel") {
                    nav.pendingPlaylistTrack = nil
                    nav.showNewPlaylist = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(creating ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func create() {
        let title = name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !creating else { return }
        creating = true
        let track = nav.pendingPlaylistTrack
        Task {
            guard let id = try? await YTM.shared.createPlaylist(title: title, privacy: privacy) else {
                creating = false
                player.showToast("Couldn't create playlist")
                return
            }
            if let track {
                _ = try? await YTM.shared.addToPlaylist(playlistId: id, videoId: track.videoId)
            }
            player.showToast(track == nil ? "Created “\(title)”" : "Created “\(title)” with \(track!.title)")
            nav.pendingPlaylistTrack = nil
            nav.showNewPlaylist = false
            library.invalidate()
        }
    }
}

/// Surfaces the live music.youtube.com page (the playback web view) so
/// account-side options like audio quality can be changed in place.
struct SiteSettingsSheet: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YouTube Music account settings")
                        .font(.headline)
                    Text("For highest quality: avatar (top right) → Settings → Playback → Audio quality → High. Saves to your account.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { player.showSiteSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            VideoSurface()
        }
        .frame(width: 960, height: 720)
    }
}

struct ContentRouter: View {
    @EnvironmentObject var nav: Nav

    var body: some View {
        Group {
            switch nav.current {
            case .home:
                ShelvesScreen(title: greeting(), loader: {
                    var shelves = (try? await YTM.shared.home()) ?? []
                    let discover = await LibraryStore.shared.discover()
                    if !discover.isEmpty {
                        shelves.insert(Shelf(title: "Discover · Fresh for you",
                                             items: discover.map { .card($0.asSongCard) }), at: 0)
                    }
                    // Latest episodes from subscribed shows ("New Episodes" /
                    // RDPN auto-playlist) — podcasts otherwise live two clicks
                    // deep. Inserted last so it lands at the very top.
                    if PodcastFeature.enabled {
                        let episodes = ((try? await YTM.shared.playlist(id: "RDPN"))?.tracks ?? [])
                            .filter(\.isEpisode)
                        if !episodes.isEmpty {
                            shelves.insert(Shelf(title: "New Podcast Episodes",
                                                 items: episodes.prefix(8).map { .track($0) }), at: 0)
                        }
                    }
                    return shelves
                }, showsSignInPrompt: true, cacheKey: "home")
                    .id("home")
            case .explore:
                ShelvesScreen(title: "Explore", loader: {
                    // Charlie's genre: lead Explore with R&B — YouTube Music's
                    // own "R&B & soul" category, plus the long DJ remix mixes
                    // that only exist as videos.
                    async let baseTask = (try? await YTM.shared.explore()) ?? []
                    async let rnbTask = (try? await YTM.shared.genre(params: YTM.Genre.rnbParams)) ?? []
                    async let remixTask = (try? await YTM.shared.search("R&B remix mix", filter: .videos))?
                        .shelves.flatMap(\.items) ?? []
                    async let classicsTask = (try? await YTM.shared.classics()) ?? []

                    var shelves = await baseTask
                    // Classics (the Queen / Michael Jackson era) sit under the
                    // whole R&B block, which is inserted above them below.
                    let classics = await classicsTask
                    if !classics.isEmpty {
                        shelves.insert(contentsOf: WeeklyRotation.rotateItems(in: classics), at: 0)
                    }
                    // Rotate BEFORE trimming, so the 20 shown are a different
                    // slice each week rather than the same 20 reordered.
                    let remixes = WeeklyRotation.rotate(await remixTask)
                    if !remixes.isEmpty {
                        shelves.insert(Shelf(title: "R&B Remixes & DJ Mixes",
                                             items: Array(remixes.prefix(20))), at: 0)
                    }
                    // Genre shelves already carry their own titles; prefix them
                    // so they read as one R&B section rather than generic rows.
                    // Rotated weekly — these pages are editorial and otherwise
                    // show the same lead track for days.
                    let rnb = WeeklyRotation.rotateItems(in: await rnbTask)
                    for shelf in rnb.prefix(4).reversed() {
                        let titled = Shelf(title: shelf.title.localizedCaseInsensitiveContains("r&b")
                                           ? shelf.title : "R&B · \(shelf.title)",
                                           items: shelf.items, moreBrowseId: shelf.moreBrowseId)
                        shelves.insert(titled, at: 0)
                    }
                    return shelves
                }, cacheKey: "explore")
                    .id("explore")
            case .library(let tab):
                LibraryView(tab: tab)
                    .id("library-\(tab.rawValue)")
            case .search(let query, let filter):
                SearchView(query: query, initialFilter: filter)
                    .id("search-\(query)")
            case .album(let id):
                CollectionView(kind: .album(id))
                    .id("album-\(id)")
            case .playlist(let id):
                CollectionView(kind: .playlist(id))
                    .id("playlist-\(id)")
            case .artist(let id):
                ArtistView(browseId: id)
                    .id("artist-\(id)")
            case .podcastShow(let id):
                PodcastView(browseId: id)
                    .id("podcast-\(id)")
            case .browse(let id):
                BrowseScreen(browseId: id)
                    .id("browse-\(id)")
            case .mostPlayed:
                MostPlayedView()
                    .id("mostPlayed")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ⌘R bumps reloadToken, changing this identity so the current page
        // tears down and re-runs its loader.
        .id(nav.reloadToken)
    }

    private func greeting() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: PlayerEngine

    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                NavButton(icon: "chevron.left", enabled: nav.canGoBack) { nav.goBack() }
                NavButton(icon: "chevron.right", enabled: nav.canGoForward) { nav.goForward() }
            }

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Search songs, albums, artists…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        let q = searchText.trimmingCharacters(in: .whitespaces)
                        guard !q.isEmpty else { return }
                        nav.go(.search(q, nil))
                        searchText = ""
                        // Release focus so Space toggles playback again.
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                Text("⌘K")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(width: 340)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))

            Spacer()

            Menu {
                if auth.isSignedIn {
                    Text("Signed in to YouTube Music")
                    Divider()
                    Button("Audio Quality & Site Settings…") {
                        player.videoMode = false
                        player.showSiteSettings = true
                    }
                    Divider()
                    Button("Sign Out") {
                        Task { await auth.signOut() }
                    }
                } else {
                    Button("Sign in with Google…") {
                        auth.showLogin = true
                    }
                }
            } label: {
                Image(systemName: auth.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(auth.isSignedIn ? Theme.textPrimary : Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.bg)
    }
}

struct NavButton: View {
    let icon: String
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering && enabled ? Theme.cardHover : Theme.card))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Keeps the shared playback web view alive inside the window.
struct PlayerWebHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        let engine = PlayerEngine.shared
        engine.parkContainer = view
        if engine.webView.superview == nil {
            engine.webView.frame = NSRect(x: 0, y: 0, width: 2, height: 2)
            view.addSubview(engine.webView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
