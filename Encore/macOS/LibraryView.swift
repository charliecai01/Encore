import SwiftUI
import EncoreCore

enum SongSort: String, CaseIterable {
    case recent = "Recently Added"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    /// YOUR play counts (PlayCounts); Least Played surfaces never-played songs.
    case mostPlayed = "Most Played"
    case leastPlayed = "Least Played"

    /// Hidden while personal play counts are flagged off.
    static var visible: [SongSort] {
        allCases.filter { PlayCountsFeature.enabled || ($0 != .mostPlayed && $0 != .leastPlayed) }
    }
}

enum CardSort: String, CaseIterable {
    case recent = "Recently Added"
    case title = "Title"
    case artist = "Artist"
}

struct LibraryView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav

    let tab: LibraryTab

    @State private var cards: [CardItem] = []
    @State private var tracks: [Track] = []
    @State private var shelves: [Shelf] = []
    @State private var loading = true
    @State private var error: String?
    @State private var songSort: SongSort = .recent
    @State private var cardSort: CardSort = .recent
    @State private var filterText = ""

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 8)]

    private var visibleTracks: [Track] {
        let order: TrackOrder
        switch songSort {
        case .recent: order = .source
        case .title: order = .title
        case .artist: order = .artist
        case .album: order = .album
        case .mostPlayed: order = .mostPlayed
        case .leastPlayed: order = .leastPlayed
        }
        return LibrarySort.arrange(tracks, query: filterText, order: order)
    }

    private var visibleCards: [CardItem] {
        let order: CardOrder
        switch cardSort {
        case .recent: order = .source
        case .title: order = .title
        case .artist: order = .subtitle
        }
        return LibrarySort.arrangeCards(cards, query: filterText, order: order)
    }

    var body: some View {
        Group {
            if !auth.isSignedIn {
                VStack(spacing: 16) {
                    Image(systemName: "lock.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Your library lives behind your Google account")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    PillButton(title: "Sign in with Google", icon: "person.crop.circle", prominent: true) {
                        auth.showLogin = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading {
                LoadingView(message: tab == .songs
                            ? "Gathering songs from your likes and all playlists…"
                            : "Loading…")
            } else if let error {
                ErrorView(message: error) {
                    Task { await load() }
                }
            } else {
                content
            }
        }
        .task(id: auth.isSignedIn) {
            if let saved = UserDefaults.standard.string(forKey: "sort-library-songs"),
               let savedSort = SongSort(rawValue: saved) {
                songSort = savedSort
            }
            if let saved = UserDefaults.standard.string(forKey: "sort-library-cards-\(tab.rawValue)"),
               let savedSort = CardSort(rawValue: saved) {
                cardSort = savedSort
            }
            guard auth.isSignedIn else { return }
            await load()
        }
        .onChange(of: songSort) { _, newSort in
            UserDefaults.standard.set(newSort.rawValue, forKey: "sort-library-songs")
        }
        .onChange(of: cardSort) { _, newSort in
            UserDefaults.standard.set(newSort.rawValue, forKey: "sort-library-cards-\(tab.rawValue)")
        }
    }

    private var cardSortOptions: [CardSort] {
        // Full options in every Library tab.
        CardSort.allCases
    }

    /// On the Artists tab a card's title IS the artist name.
    private func cardSortLabel(_ sort: CardSort) -> String {
        tab == .artists && sort == .title ? "Name" : sort.rawValue
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Text(tab.rawValue)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if tab == .songs && !tracks.isEmpty {
                        Spacer()
                        PillButton(title: "Play All", icon: "play.fill", prominent: true) {
                            player.playCollection(visibleTracks, startAt: 0)
                        }
                        PillButton(title: "Shuffle", icon: "shuffle") {
                            player.playShuffled(visibleTracks)
                        }
                    }
                    if tab == .playlists {
                        Spacer()
                        PillButton(title: "New Playlist", icon: "plus", prominent: true) {
                            nav.showNewPlaylist = true
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                if tab != .history && !(tracks.isEmpty && cards.isEmpty) {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                            TextField("Filter", text: $filterText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                            if !filterText.isEmpty {
                                Button {
                                    filterText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(width: 220)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.stroke))

                        if tab == .songs {
                            Menu {
                                ForEach(SongSort.visible, id: \.self) { sort in
                                    Button {
                                        songSort = sort
                                    } label: {
                                        if songSort == sort {
                                            Label(sort.rawValue, systemImage: "checkmark")
                                        } else {
                                            Text(sort.rawValue)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(songSort.rawValue)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(Theme.textSecondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        } else if tab != .history {
                            Menu {
                                ForEach(cardSortOptions, id: \.self) { sort in
                                    Button {
                                        cardSort = sort
                                    } label: {
                                        if cardSort == sort {
                                            Label(cardSortLabel(sort), systemImage: "checkmark")
                                        } else {
                                            Text(cardSortLabel(sort))
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(cardSortLabel(cardSort))
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(Theme.textSecondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }

                switch tab {
                case .songs:
                    let shown = visibleTracks
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, track in
                            TrackRow(track: track) {
                                player.playCollection(shown, startAt: i)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    if tracks.isEmpty {
                        EmptyLibraryNote(text: "Songs you like will show up here.")
                    }
                case .history:
                    ForEach(shelves) { shelf in
                        ShelfView(shelf: shelf)
                    }
                    if shelves.isEmpty {
                        EmptyLibraryNote(text: "Your listening history will show up here.")
                    }
                default:
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(visibleCards) { card in
                            CardView(item: card, flexible: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    if cards.isEmpty {
                        EmptyLibraryNote(text: "Nothing saved here yet.")
                    }
                }
            }
            .padding(.bottom, 36)
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            switch tab {
            case .playlists:
                // Same local custom order as the sidebar.
                cards = LibraryStore.shared.applyCustomOrder(try await YTM.shared.libraryPlaylists())
            case .songs:
                tracks = await LibraryStore.shared.allKnownTracks()
            case .albums:
                cards = try await YTM.shared.libraryAlbums()
            case .artists:
                // Build from the whole collection (likes + all playlists),
                // merged with YouTube's library-artist list for portraits.
                let corpus = (try? await YTM.shared.libraryArtists()) ?? []
                let allTracks = await LibraryStore.shared.allKnownTracks()
                cards = LibrarySort.artistCards(corpus: corpus, tracks: allTracks)
            case .podcasts:
                cards = try await YTM.shared.libraryPodcasts()
            case .history:
                shelves = try await YTM.shared.history()
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct EmptyLibraryNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 24)
            .padding(.top, 8)
    }
}
