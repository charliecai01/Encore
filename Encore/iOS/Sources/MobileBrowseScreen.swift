import SwiftUI
import EncoreCore

// MARK: - Browse (library-artist / generic)

struct BrowseScreen: View {
    let browseId: String
    @State private var title = ""
    @State private var shelves: [Shelf] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 80) }
                ForEach(shelves) { ShelfRow(shelf: $0) }
                Color.clear.frame(height: 80)
            }.padding(.top, 8)
        }
        .background(Theme.bg)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task {
            if let p = try? await YTM.shared.browsePage(browseId: browseId) { title = p.title; shelves = p.shelves }
            loading = false
        }
    }
}
