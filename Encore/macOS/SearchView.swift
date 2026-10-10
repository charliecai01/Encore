import SwiftUI
import EncoreCore

struct SearchView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav

    let query: String
    let initialFilter: YTM.SearchFilter?

    @State private var filter: YTM.SearchFilter?
    @State private var results = SearchResults()
    @State private var loading = true
    @State private var error: String?
    @State private var loadedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                FilterChip(title: "All", selected: filter == nil) {
                    filter = nil
                }
                ForEach(YTM.SearchFilter.allCases, id: \.self) { f in
                    FilterChip(title: f.title, selected: filter == f) {
                        filter = f
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            if loading {
                LoadingView()
            } else if let error {
                ErrorView(message: error) {
                    Task { await load() }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        // The top hit is just the first row — no separate
                        // banner card (Charlie, 2026-10-09).
                        if let top = results.top {
                            Group {
                                switch top {
                                case .track(let track):
                                    TrackRow(track: track, showsAlbum: false) {
                                        player.playRadio(from: track)
                                    }
                                case .card(let card):
                                    CardRow(item: card)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        ForEach(results.shelves) { shelf in
                            if filter != nil && !shelf.isTrackShelf {
                                // A single-kind filter (Albums, Artists, Playlists)
                                // is the whole page — vertical rows, not one
                                // sideways carousel. Same as iOS.
                                cardList(shelf)
                            } else {
                                ShelfView(shelf: shelf)
                            }
                        }
                        if results.top == nil && results.shelves.isEmpty {
                            Text("No results for “\(query)”")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(24)
                        }
                    }
                    .padding(.bottom, 36)
                }
            }
        }
        .onAppear {
            if !loadedOnce {
                loadedOnce = true
                filter = initialFilter
            }
        }
        .task(id: filter) {
            await load()
        }
    }

    private func cardList(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !shelf.title.isEmpty {
                Text(shelf.title).font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 24)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                    if case .card(let card) = item { CardRow(item: card) }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            results = try await YTM.shared.search(query, filter: filter)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? .black : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(selected ? Color.white : (hovering ? Theme.cardHover : Theme.card))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - ⌘K palette

struct CommandPalette: View {
    @EnvironmentObject var nav: Nav

    @State private var text = ""
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { nav.paletteShown = false }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Search YouTube Music…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onSubmit { submit(text) }
                    if !text.isEmpty {
                        Button {
                            text = ""
                            suggestions = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 54)

                if !suggestions.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(suggestions.prefix(8), id: \.self) { suggestion in
                            PaletteRow(text: suggestion) {
                                submit(suggestion)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(.top, 120)
        }
        .onAppear { focused = true }
        .onExitCommand { nav.paletteShown = false }
        .task(id: text) {
            let q = text.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else {
                suggestions = []
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            suggestions = (try? await YTM.shared.suggestions(q)) ?? []
        }
    }

    private func submit(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        nav.paletteShown = false
        nav.go(.search(q, nil))
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

struct PaletteRow: View {
    let text: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(hovering ? Theme.cardHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
