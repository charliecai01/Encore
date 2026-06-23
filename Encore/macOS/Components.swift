import SwiftUI
import EncoreCore

// MARK: - Artwork image

struct ArtworkView: View {
    let url: URL?
    var corner: CGFloat = 8

    var body: some View {
        Color.clear
            .overlay {
                RemoteImage(url: url)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Card (album / playlist / artist / mix)

struct CardView: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: PlayerEngine
    let item: CardItem
    var width: CGFloat = 168
    /// In adaptive grids the cell decides the width; fixed sizing would clip
    /// neighbors when the window resizes.
    var flexible = false

    @State private var hovering = false

    private var isArtist: Bool { item.kind == .artist }

    var body: some View {
        Button {
            nav.open(item)
        } label: {
            VStack(alignment: isArtist ? .center : .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    // Radius is clamped to half the side, so 999 = circle.
                    artwork(corner: isArtist ? 999 : 10)
                        .shadow(color: .black.opacity(hovering ? 0.5 : 0.25), radius: hovering ? 14 : 8, y: 4)

                    if hovering && !isArtist {
                        PlayBadge {
                            playItem()
                        }
                        .padding(10)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                VStack(alignment: isArtist ? .center : .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(isArtist ? .center : .leading)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: flexible ? .infinity : width,
                       alignment: isArtist ? .center : .leading)
            }
            .frame(maxWidth: flexible ? .infinity : nil)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(hovering, corner: 12)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
    }

    @ViewBuilder
    private func artwork(corner: CGFloat) -> some View {
        if flexible {
            ArtworkView(url: Artwork.upscale(item.thumbnailURL, to: 336), corner: corner)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            ArtworkView(url: Artwork.upscale(item.thumbnailURL, to: 336), corner: corner)
                .frame(width: width, height: width)
        }
    }

    private func playItem() {
        switch item.kind {
        case .album:
            if let browseId = item.browseId {
                Task {
                    if let page = try? await YTM.shared.album(browseId: browseId), !page.tracks.isEmpty {
                        player.playCollection(page.tracks, startAt: 0)
                    }
                }
            }
        case .playlist where item.playlistId?.hasPrefix("RD") == false:
            if let id = item.playlistId {
                Task {
                    if let page = try? await YTM.shared.playlist(id: id), !page.tracks.isEmpty {
                        player.playCollection(page.tracks, startAt: 0)
                    }
                }
            }
        default:
            nav.open(item)
        }
    }
}

struct PlayBadge: View {
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white)
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Track row

struct TrackRow: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore

    let track: Track
    var index: Int? = nil
    var showsArtwork = true
    var showsAlbum = true
    /// Set by playlist pages: enables "Remove from this Playlist".
    var onRemoveFromPlaylist: (() -> Void)? = nil
    let onPlay: () -> Void

    @State private var hovering = false
    @State private var swipeOffset: CGFloat = 0
    @State private var rowId = UUID().uuidString

    private var isCurrent: Bool { player.current?.videoId == track.videoId }
    private var liked: Bool { player.likedIds.contains(track.videoId) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if showsArtwork {
                    ArtworkView(url: track.thumbnailURL, corner: 5)
                        .frame(width: 40, height: 40)
                        .opacity(hovering ? 0.4 : 1)
                } else if let index {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(isCurrent ? Theme.fallbackAccent : Theme.textSecondary)
                        .opacity(hovering ? 0 : 1)
                }
                if hovering {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                if isCurrent && player.isPlaying && !hovering && showsArtwork {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.black.opacity(0.45))
                        .frame(width: 40, height: 40)
                    NowPlayingBars()
                }
            }
            .frame(width: showsArtwork ? 40 : 28, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isCurrent ? Theme.fallbackAccent : Theme.textPrimary)
                    .lineLimit(1)
                Text(track.artistLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsAlbum, let album = track.album {
                Text(album.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 240, alignment: .leading)
            }

            if hovering {
                Button {
                    player.toggleLike(track)
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(liked ? Theme.fallbackAccent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            } else if liked {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.fallbackAccent.opacity(0.8))
            }

            Text(track.durationText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .offset(x: swipeOffset)
        .background(swipeBackground)
        .hoverHighlight(hovering)
        .onHover { h in
            hovering = h
            if h {
                registerForSwipes()
            } else {
                SwipeRouter.shared.unregister(id: rowId)
                if swipeOffset != 0 {
                    withAnimation(.spring(duration: 0.25)) { swipeOffset = 0 }
                }
            }
        }
        .onTapGesture(count: 2) { onPlay() }
        .onTapGesture {
            // Pull keyboard focus out of any text field so Space reliably
            // toggles playback after interacting with lists.
            NSApp.keyWindow?.makeFirstResponder(nil)
            if isCurrent { player.togglePlay() } else { onPlay() }
        }
        .contextMenu {
            Button("Play") { onPlay() }
            Button("Play Next") { player.playNext(track) }
            Button("Add to Queue") { player.addToQueue(track) }
            Divider()
            Button("Start Radio") { player.playRadio(from: track) }
            if let url = track.shareURL {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Divider()
            Menu("Add to Playlist") {
                Button("New Playlist…") {
                    nav.pendingPlaylistTrack = track
                    nav.showNewPlaylist = true
                }
                if !editablePlaylists.isEmpty {
                    Divider()
                    ForEach(editablePlaylists) { playlist in
                        Button(playlist.title) {
                            addToPlaylist(playlist)
                        }
                    }
                }
            }
            Divider()
            if let albumId = track.album?.id {
                Button("Go to Album") { nav.go(.album(albumId)) }
            }
            if let artist = track.artists.first {
                Button("Go to Artist") { nav.goArtist(id: artist.id, name: artist.name) }
            }
            Divider()
            Button(liked ? "Remove from Liked" : "Add to Liked") { player.toggleLike(track) }
            if let onRemoveFromPlaylist {
                Button("Remove from this Playlist", role: .destructive) { onRemoveFromPlaylist() }
            }
        }
    }

    /// Trackpad swipe actions: right = add to queue, left = remove from
    /// playlist (on playlist pages).
    private func registerForSwipes() {
        SwipeRouter.shared.install()
        SwipeRouter.shared.target = SwipeRouter.Target(
            id: rowId,
            canSwipeLeft: onRemoveFromPlaylist != nil,
            canSwipeRight: true,
            onChange: { value in
                swipeOffset = max(-130, min(130, value))
            },
            onEnd: { value in
                if value > 70 {
                    player.addToQueue(track)
                } else if value < -70 {
                    onRemoveFromPlaylist?()
                }
                withAnimation(.spring(duration: 0.3)) { swipeOffset = 0 }
            }
        )
    }

    private var swipeBackground: some View {
        HStack {
            Label("Add to Queue", systemImage: "text.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(swipeOffset > 25 ? 1 : 0)
            Spacer()
            Label("Remove", systemImage: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(swipeOffset < -25 ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(swipeOffset > 0
                      ? Theme.fallbackAccent.opacity(min(0.8, swipeOffset / 130))
                      : Color.red.opacity(min(0.8, -swipeOffset / 130)))
        )
        .opacity(swipeOffset == 0 ? 0 : 1)
    }

    private var editablePlaylists: [CardItem] {
        library.playlists.filter { playlist in
            guard let id = playlist.playlistId else { return false }
            return id != "LM" && !id.hasPrefix("RD")
        }
    }

    private func addToPlaylist(_ playlist: CardItem) {
        guard let playlistId = playlist.playlistId else { return }
        Task {
            let ok = (try? await YTM.shared.addToPlaylist(playlistId: playlistId,
                                                          videoId: track.videoId)) ?? false
            if ok {
                player.showToast("Added to \(playlist.title)")
                PageCache.shared.collections["playlist-\(playlistId)"] = nil
            } else {
                player.showToast("Couldn't add to \(playlist.title) — you can only edit your own playlists")
            }
        }
    }
}

struct NowPlayingBars: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3, height: animating ? 14 : 4)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .frame(height: 16, alignment: .bottom)
        .onAppear { animating = true }
    }
}

// MARK: - Shelf

struct ShelfView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var nav: Nav
    let shelf: Shelf

    @State private var availableWidth: CGFloat = 0

    /// Playlist behind the shelf's "more" link (e.g. an artist's full Top songs,
    /// ranked by plays). Only surfaced for track shelves that link to a playlist.
    private var allSongsPlaylistId: String? {
        guard shelf.isTrackShelf, let id = shelf.moreBrowseId, id.hasPrefix("VL") else { return nil }
        return String(id.dropFirst(2))
    }

    private let cardSpacing: CGFloat = 12
    private let edgeInset: CGFloat = 16

    /// Size cards so a whole number fit the row exactly — no clipped
    /// neighbors at any window size.
    private var cardWidth: CGFloat {
        guard availableWidth > 0 else { return 168 }
        let inner = availableWidth - edgeInset * 2
        let idealOuter: CGFloat = 184  // card width 168 + internal padding
        let count = max(2, Int((inner + cardSpacing) / (idealOuter + cardSpacing)))
        let outer = (inner - cardSpacing * CGFloat(count - 1)) / CGFloat(count)
        return max(120, outer - 16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !shelf.title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(shelf.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let plId = allSongsPlaylistId {
                        Button { nav.go(.playlist(plId)) } label: {
                            HStack(spacing: 3) {
                                Text("Show all")
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
            if shelf.isTrackShelf {
                LazyVStack(spacing: 0) {
                    let tracks = shelf.tracks
                    ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                        switch item {
                        case .track(let track):
                            TrackRow(track: track, showsAlbum: false) {
                                let i = tracks.firstIndex(of: track) ?? 0
                                player.playCollection(tracks, startAt: i)
                            }
                        case .card(let card):
                            CardRow(item: card)
                        }
                    }
                }
                .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: cardSpacing) {
                        ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                            if case .card(let card) = item {
                                CardView(item: card, width: cardWidth)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, edgeInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    availableWidth = newWidth
                }
            }
        }
    }
}

/// List-row rendering of a card item, used in mixed search results.
struct CardRow: View {
    @EnvironmentObject var nav: Nav

    let item: CardItem

    @State private var hovering = false

    var body: some View {
        Button {
            nav.open(item)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: item.thumbnailURL, corner: item.kind == .artist ? 20 : 5)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - States

struct LoadingView: View {
    var message = "Loading…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pill button

struct PillButton: View {
    let title: String
    let icon: String
    var prominent = false
    var tint: Color = .white
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(prominent ? tint : Color.white.opacity(hovering ? 0.16 : 0.09))
            )
            .overlay(
                Capsule().strokeBorder(prominent ? .clear : Theme.stroke)
            )
            .foregroundStyle(prominent ? Color.black : Theme.textPrimary)
            .scaleEffect(hovering ? 1.03 : 1)
            // Keep the pill intact when surrounding space shrinks (e.g. the
            // queue panel opening) instead of wrapping the label vertically.
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
