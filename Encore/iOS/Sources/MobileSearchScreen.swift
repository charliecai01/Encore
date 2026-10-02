import SwiftUI
import EncoreCore

// MARK: - Search

struct SearchScreen: View {
    var initialQuery: String = ""
    var initialFilter: YTM.SearchFilter? = nil

    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    @State private var query = ""
    @State private var filter: YTM.SearchFilter?
    @State private var results = SearchResults()
    @State private var loading = false
    @State private var started = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                // All six pills share one row, no sideways scrolling (Charlie,
                // 2026-10-01): each takes an equal slice and the label shrinks
                // a touch if "Playlists" wouldn't otherwise fit.
                HStack(spacing: 6) {
                    chip("All", filter == nil) { filter = nil; Task { await run() } }
                    ForEach(YTM.SearchFilter.allCases, id: \.self) { f in
                        chip(f.title, filter == f) { filter = f; Task { await run() } }
                    }
                }
                .padding(.horizontal, 16)

                if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                ForEach(results.shelves) { shelf in
                    if shelf.isTrackShelf {
                        VStack(spacing: 0) {
                            ForEach(Array(shelf.tracks.enumerated()), id: \.offset) { i, t in
                                TrackRowView(track: t, onRemoveFromPlaylist: nil) {
                                    player.playCollection(shelf.tracks, startAt: i)
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    } else if filter != nil {
                        // A single-kind filter (Albums, Artists, …) is the whole
                        // page, so it reads as a vertical grid like Library
                        // rather than one sideways carousel.
                        cardGrid(shelf)
                    } else {
                        ShelfRow(shelf: shelf)
                    }
                }
                Color.clear.frame(height: 80)
            }
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, albums, artists…")
        .onSubmit(of: .search) { Task { await run() } }
        .task {
            guard !started else { return }
            started = true
            if !initialQuery.isEmpty { query = initialQuery; filter = initialFilter; await run() }
        }
    }

    private func cardGrid(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !shelf.title.isEmpty {
                Text(shelf.title).font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 16) {
                ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                    if case .card(let card) = item { CardCircleOrSquare(item: card) }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func chip(_ title: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? .black : Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 4).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(selected ? Color.white : Theme.card))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let f = filter
        loading = true
        let fresh = (try? await YTM.shared.search(q, filter: f)) ?? SearchResults()
        // A pill tapped while an earlier search is in flight starts its own;
        // if that earlier one lands last it must not overwrite the newer
        // results (the "Artists" pill showing the All tab's songs).
        guard f == filter, q == query.trimmingCharacters(in: .whitespaces) else { return }
        results = fresh
        loading = false
    }
}
