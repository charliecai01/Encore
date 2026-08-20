import SwiftUI
import EncoreCore

// MARK: - Library

struct LibraryScreen: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var library: LibraryStore
    @State private var tab: LibraryTab = .playlists
    @State private var cards: [CardItem] = []
    @State private var tracks: [Track] = []
    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var filter = ""
    @State private var songSort: SortMode = .recent
    @State private var cardSort: SortMode = .recent

    private let cols = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    private var visibleTracks: [Track] {
        TrackSort.apply(tracks, filter: filter, sort: songSort, keepOrder: false)
    }
    private var visibleCards: [CardItem] {
        TrackSort.cards(cards, filter: filter, sort: cardSort)
    }
    private var sortOptions: [SortMode] {
        // Full options in every Library tab.
        var opts: [SortMode] = [.recent, .title, .artist, .album]
        if PlayCountsFeature.enabled { opts += [.mostPlayed, .leastPlayed] }
        return opts
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $tab) {
                    ForEach(LibraryTab.visible, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if auth.isSignedIn && !loading && tab != .mostPlayed && tab != .history {
                    SortFilterBar(filter: $filter,
                                  sort: tab == .songs ? $songSort : $cardSort,
                                  sortOptions: sortOptions,
                                  sortLabel: { tab == .artists && $0 == .title ? "Name" : $0.rawValue })
                }

                if !auth.isSignedIn {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.circle").font(.system(size: 40)).foregroundStyle(Theme.textTertiary)
                        Text("Sign in to see your library").foregroundStyle(Theme.textSecondary)
                        Button("Sign in with Google") { auth.showLogin = true }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if tab == .mostPlayed {
                    MostPlayedList()
                } else if tab == .history {
                    if shelves.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(Theme.textTertiary)
                            Text("No history yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            Text("Songs you play show up here, grouped by when you played them.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                                .multilineTextAlignment(.center).padding(.horizontal, 40)
                        }.frame(maxWidth: .infinity).padding(.top, 80)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(shelves) { ShelfRow(shelf: $0) }
                        }
                    }
                } else if tab == .songs {
                    let shown = visibleTracks
                    if shown.count > 1 {
                        HStack(spacing: 10) {
                            Button { player.playCollection(shown, startAt: 0) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            Button { player.playShuffled(shown) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                        }.padding(.horizontal, 16)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                            TrackRowView(track: t, onRemoveFromPlaylist: nil) { player.playCollection(shown, startAt: i) }
                                .padding(.horizontal, 16)
                        }
                    }
                } else {
                    LazyVGrid(columns: cols, spacing: 16) {
                        ForEach(visibleCards) { CardCircleOrSquare(item: $0) }
                    }
                    .padding(.horizontal, 16)
                }
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Library")
        .toolbar { accountButton }
        .refreshable { await load(force: true) }
        .task(id: "\(auth.isSignedIn)-\(tab.rawValue)") { restoreSort(); await load() }
        // The Songs list is handed a snapshot of the track cache, so when the
        // background refresh lands it has to be told to pick the new one up.
        .onChange(of: library.allTracksVersion) { _, _ in
            guard tab == .songs else { return }
            Task { tracks = await LibraryStore.shared.allKnownTracks() }
        }
        .onChange(of: songSort) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "sort-lib-songs") }
        .onChange(of: cardSort) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "sort-lib-\(tab.rawValue)") }
    }

    private func restoreSort() {
        if let s = UserDefaults.standard.string(forKey: "sort-lib-songs").flatMap(SortMode.init) { songSort = s }
        if let s = UserDefaults.standard.string(forKey: "sort-lib-\(tab.rawValue)").flatMap(SortMode.init) { cardSort = s }
        else { cardSort = .recent }
    }

    private func load(force: Bool = false) async {
        guard auth.isSignedIn else { return }
        loading = true
        switch tab {
        case .playlists: cards = (try? await YTM.shared.libraryPlaylists()) ?? []
        case .songs: tracks = await LibraryStore.shared.allKnownTracks(forceRefresh: force)
        case .albums: cards = (try? await YTM.shared.libraryAlbums()) ?? []
        case .artists:
            let corpus = (try? await YTM.shared.libraryArtists()) ?? []
            let all = await LibraryStore.shared.allKnownTracks()
            cards = LibrarySort.artistCards(corpus: corpus, tracks: all)
        case .podcasts:
            cards = (try? await YTM.shared.libraryPodcasts()) ?? []
        case .mostPlayed:
            break   // PlayCounts is local; MostPlayedList loads it itself.
        case .history:
            shelves = (try? await YTM.shared.history()) ?? []
        }
        loading = false
    }

}
