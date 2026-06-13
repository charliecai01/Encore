import SwiftUI
import EncoreCore

enum SongSort: String, CaseIterable {
    case recent = "Recently Added"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
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
        var result = tracks
        let q = filterText.trimmingCharacters(in: .whitespaces).matchNormalized
        if !q.isEmpty {
            result = result.filter {
                $0.title.matches(normalizedQuery: q)
                    || $0.artistLine.matches(normalizedQuery: q)
                    || ($0.album?.name.matches(normalizedQuery: q) ?? false)
            }
        }
        switch songSort {
        case .recent:
            return result
        case .title:
            return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return result.sorted {
                let cmp = $0.artistLine.localizedCaseInsensitiveCompare($1.artistLine)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .album:
            return result.sorted {
                let a0 = $0.album?.name ?? "~", a1 = $1.album?.name ?? "~"
                let cmp = a0.localizedCaseInsensitiveCompare(a1)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private var visibleCards: [CardItem] {
        var result = cards
        let q = filterText.trimmingCharacters(in: .whitespaces).matchNormalized
        if !q.isEmpty {
            result = result.filter {
                $0.title.matches(normalizedQuery: q) || $0.subtitle.matches(normalizedQuery: q)
            }
        }
        switch cardSort {
        case .recent:
            return result
        case .title:
            return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return result.sorted {
                let cmp = $0.subtitle.localizedCaseInsensitiveCompare($1.subtitle)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
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
        tab == .albums ? CardSort.allCases : [.recent, .title]
    }

    /// On the Artists tab a card's title IS the artist name.
    private func cardSortLabel(_ sort: CardSort) -> String {
        tab == .artists && sort == .title ? "Artist" : sort.rawValue
    }

    /// One card per artist across the entire collection. Prefers YouTube's
    /// corpus entries (artist portraits), adds everyone else found in
    /// playlists, and counts songs from the full aggregate.
    static func artistCards(corpus: [CardItem], tracks: [Track]) -> [CardItem] {
        struct Tally {
            var name: String
            var count = 0
            var thumb: URL?
        }
        var byId: [String: Tally] = [:]
        var byName: [String: Tally] = [:]

        for track in tracks {
            if track.artists.isEmpty {
                let name = track.artistLine
                    .components(separatedBy: CharacterSet(charactersIn: ",&"))
                    .first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !name.isEmpty else { continue }
                var tally = byName[name.matchNormalized] ?? Tally(name: name)
                tally.count += 1
                if tally.thumb == nil { tally.thumb = track.thumbnailURL }
                byName[name.matchNormalized] = tally
                continue
            }
            for ref in track.artists {
                // Only real channels make a navigable card; library-private
                // artist refs group by name instead.
                if let id = ref.id, id.hasPrefix("UC") {
                    var tally = byId[id] ?? Tally(name: ref.name)
                    tally.count += 1
                    if tally.thumb == nil { tally.thumb = track.thumbnailURL }
                    byId[id] = tally
                } else if !ref.name.isEmpty {
                    var tally = byName[ref.name.matchNormalized] ?? Tally(name: ref.name)
                    tally.count += 1
                    if tally.thumb == nil { tally.thumb = track.thumbnailURL }
                    byName[ref.name.matchNormalized] = tally
                }
            }
        }

        func countLabel(_ n: Int) -> String {
            "\(n) song\(n == 1 ? "" : "s")"
        }

        var out: [CardItem] = []
        var seenIds = Set<String>()
        var seenNames = Set<String>()

        for card in corpus {
            let channelId = card.browseId.map { $0.hasPrefix("MPLA") ? String($0.dropFirst(4)) : $0 }
            var item = card
            if let channelId, let tally = byId[channelId] {
                item.subtitle = countLabel(tally.count)
            }
            out.append(item)
            if let channelId { seenIds.insert(channelId) }
            seenNames.insert(card.title.matchNormalized)
        }
        // "Jacky Cheung" from an upload duplicates "張學友 - Jacky Cheung";
        // suppress aggregated cards whose name is contained in (or contains)
        // an artist we already show.
        func isDuplicate(_ name: String) -> Bool {
            let n = name.matchNormalized
            guard n.count >= 3 else { return seenNames.contains(n) }
            return seenNames.contains { $0.contains(n) || n.contains($0) }
        }

        for (id, tally) in byId.sorted(by: { $0.value.count > $1.value.count })
        where !seenIds.contains(id) && !isDuplicate(tally.name) {
            seenNames.insert(tally.name.matchNormalized)
            out.append(CardItem(kind: .artist, title: tally.name, subtitle: countLabel(tally.count),
                                thumbnailURL: tally.thumb, browseId: id))
        }
        for (key, tally) in byName where !isDuplicate(tally.name) {
            seenNames.insert(key)
            out.append(CardItem(kind: .artist, title: tally.name, subtitle: countLabel(tally.count),
                                thumbnailURL: tally.thumb))
        }

        // Most-collected artists first.
        func count(_ item: CardItem) -> Int {
            Int(item.subtitle.components(separatedBy: " ").first ?? "") ?? 0
        }
        return out.sorted {
            let c0 = count($0), c1 = count($1)
            if c0 != c1 { return c0 > c1 }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
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
                                ForEach(SongSort.allCases, id: \.self) { sort in
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
                cards = try await YTM.shared.libraryPlaylists()
            case .songs:
                tracks = await LibraryStore.shared.allKnownTracks()
            case .albums:
                cards = try await YTM.shared.libraryAlbums()
            case .artists:
                // Build from the whole collection (likes + all playlists),
                // merged with YouTube's library-artist list for portraits.
                let corpus = (try? await YTM.shared.libraryArtists()) ?? []
                let allTracks = await LibraryStore.shared.allKnownTracks()
                cards = Self.artistCards(corpus: corpus, tracks: allTracks)
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
