import SwiftUI
import EncoreCore

/// Generic shelf-feed screen used by Home and Explore.
struct ShelvesScreen: View {
    @EnvironmentObject var auth: AuthManager

    let title: String
    let loader: () async throws -> [Shelf]
    var showsSignInPrompt = false
    var cacheKey: String? = nil

    @State private var shelves: [Shelf] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                LoadingView()
            } else if let error, shelves.isEmpty {
                ErrorView(message: error) {
                    Task { await load() }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        Text(title)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 24)
                            .padding(.top, 18)

                        if showsSignInPrompt && !auth.isSignedIn {
                            SignInBanner()
                                .padding(.horizontal, 24)
                        }

                        ForEach(shelves) { shelf in
                            ShelfView(shelf: shelf)
                        }
                    }
                    .padding(.bottom, 36)
                }
            }
        }
        .task(id: auth.isSignedIn) {
            await load()
        }
    }

    private func load() async {
        if let cacheKey, let cached = PageCache.shared.shelves[cacheKey], !cached.isEmpty {
            shelves = cached
            loading = false
            if let fresh = try? await loader(), !fresh.isEmpty {
                shelves = fresh
                PageCache.shared.shelves[cacheKey] = fresh
            }
            return
        }
        loading = true
        error = nil
        do {
            shelves = try await loader()
            if shelves.isEmpty {
                error = "Nothing here yet. Try signing in for personalized mixes."
            } else if let cacheKey {
                PageCache.shared.shelves[cacheKey] = shelves
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// Generic browse-id page (library artist, "more" endpoints): title + shelves.
struct BrowseScreen: View {
    let browseId: String

    @State private var title = ""
    @State private var shelves: [Shelf] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                LoadingView()
            } else if let error {
                ErrorView(message: error) {
                    Task { await load() }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        Text(title.isEmpty ? "Library" : title)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 24)
                            .padding(.top, 18)
                        ForEach(shelves) { shelf in
                            ShelfView(shelf: shelf)
                        }
                    }
                    .padding(.bottom, 36)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let page = try await YTM.shared.browsePage(browseId: browseId)
            title = page.title
            shelves = page.shelves
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct SignInBanner: View {
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(Theme.fallbackAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sign in for your music")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your mixes, library, and Premium ad-free playback — right here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            PillButton(title: "Sign in", icon: "person.crop.circle", prominent: true) {
                auth.showLogin = true
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }
}
