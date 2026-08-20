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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", filter == nil) { filter = nil; Task { await run() } }
                        ForEach(YTM.SearchFilter.allCases, id: \.self) { f in
                            chip(f.title, filter == f) { filter = f; Task { await run() } }
                        }
                    }
                    .padding(.horizontal, 16)
                }

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

    private func chip(_ title: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? .black : Theme.textPrimary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.white : Theme.card))
        }
        .buttonStyle(.plain)
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        results = (try? await YTM.shared.search(q, filter: filter)) ?? SearchResults()
        loading = false
    }
}
