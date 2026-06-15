import SwiftUI
import EncoreCore

struct SidebarView: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear the traffic-light buttons (hidden title bar).
            Spacer().frame(height: 38)

            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.fallbackAccent)
                Text("Encore")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarItem(title: "Home", icon: "house.fill",
                                selected: nav.current == .home) { nav.go(.home) }
                    SidebarItem(title: "Explore", icon: "square.grid.2x2.fill",
                                selected: nav.current == .explore) { nav.go(.explore) }

                    SectionLabel("Library")
                    ForEach(LibraryTab.allCases, id: \.self) { tab in
                        SidebarItem(title: tab.rawValue, icon: tab.icon,
                                    selected: nav.current == .library(tab)) {
                            nav.go(.library(tab))
                        }
                    }

                    if auth.isSignedIn {
                        HStack {
                            SectionLabel("Playlists")
                            Spacer()
                            Button {
                                nav.showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 20, height: 20)
                                    .background(Theme.card, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("New playlist")
                            .padding(.top, 14)
                            .padding(.trailing, 6)
                        }
                        ForEach(library.playlists.prefix(20)) { playlist in
                            SidebarPlaylistItem(playlist: playlist,
                                                selected: isCurrentPlaylist(playlist)) {
                                if let id = playlist.playlistId {
                                    nav.go(.playlist(id))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 8)

            if !auth.isSignedIn {
                Button {
                    auth.showLogin = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                        Text("Sign in")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.bgElevated)
        .task(id: auth.isSignedIn) {
            await library.loadIfNeeded()
        }
    }

    private func isCurrentPlaylist(_ playlist: CardItem) -> Bool {
        if case .playlist(let id) = nav.current, id == playlist.playlistId {
            return true
        }
        return false
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .kerning(0.8)
            .padding(.horizontal, 10)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

struct SidebarItem: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.cardHover : (hovering ? Theme.card : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SidebarPlaylistItem: View {
    let playlist: CardItem
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ArtworkView(url: playlist.thumbnailURL, corner: 4)
                    .frame(width: 26, height: 26)
                Text(playlist.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.cardHover : (hovering ? Theme.card : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
