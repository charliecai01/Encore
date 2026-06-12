import CarPlay
import UIKit
import EncoreCore

/// CarPlay audio-app scene. Presents the user's playlists and library as
/// browsable lists; selecting a track starts playback and shows the system
/// Now Playing template. Requires the `com.apple.developer.carplay-audio`
/// entitlement (Apple-granted) to activate on real hardware / the CarPlay
/// simulator.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        let library = CPListTemplate(title: "Library", sections: [])
        library.tabTitle = "Library"
        library.tabImage = UIImage(systemName: "music.note.list")

        let home = CPListTemplate(title: "Home", sections: [])
        home.tabTitle = "Home"
        home.tabImage = UIImage(systemName: "house.fill")

        let tab = CPTabBarTemplate(templates: [home, library])
        interfaceController.setRootTemplate(tab, animated: true, completion: nil)

        Task { @MainActor in
            await populateHome(home)
            await populateLibrary(library)
            // Keep the Now Playing button in sync with playback state.
            PlayerEngine.shared.onStateChange = { [weak self] in self?.syncNowPlaying() }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: - Population

    @MainActor
    private func populateHome(_ template: CPListTemplate) async {
        // Fetch the home feed and the user's playlists together.
        async let shelvesTask = (try? await YTM.shared.home()) ?? []
        async let playlistsTask = (try? await YTM.shared.libraryPlaylists()) ?? []
        let shelves = await shelvesTask
        let playlists = await playlistsTask

        var sections: [CPListSection] = []

        // Your playlists, right at the top of Home.
        let playlistItems = playlists.map { playlist -> CPListItem in
            let item = CPListItem(text: playlist.title, detailText: playlist.subtitle)
            setArtwork(item, url: playlist.thumbnailURL)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in await self?.openCard(playlist); completion() }
            }
            return item
        }
        if !playlistItems.isEmpty {
            sections.append(CPListSection(items: playlistItems, header: "Your Playlists", sectionIndexTitle: nil))
        }

        for shelf in shelves.prefix(6) {
            var items: [CPListItem] = []
            for case .card(let card) in shelf.items.prefix(12) {
                let item = CPListItem(text: card.title, detailText: card.subtitle)
                setArtwork(item, url: card.thumbnailURL)
                item.handler = { [weak self] _, completion in
                    Task { @MainActor in await self?.openCard(card); completion() }
                }
                items.append(item)
            }
            for case .track(let track) in shelf.items.prefix(12) {
                let item = CPListItem(text: track.title, detailText: track.artistLine)
                setArtwork(item, url: track.thumbnailURL)
                item.handler = { [weak self] _, completion in
                    PlayerEngine.shared.playRadio(from: track)
                    self?.pushNowPlaying(); completion()
                }
                items.append(item)
            }
            if !items.isEmpty { sections.append(CPListSection(items: items, header: shelf.title, sectionIndexTitle: nil)) }
        }
        template.updateSections(sections)
    }

    @MainActor
    private func populateLibrary(_ template: CPListTemplate) async {
        let playlists = (try? await YTM.shared.libraryPlaylists()) ?? []
        let items = playlists.map { playlist -> CPListItem in
            let item = CPListItem(text: playlist.title, detailText: playlist.subtitle)
            setArtwork(item, url: playlist.thumbnailURL)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in await self?.openCard(playlist); completion() }
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
    }

    // MARK: - Navigation

    @MainActor
    private func openCard(_ card: CardItem) async {
        switch card.kind {
        case .playlist:
            guard let id = card.playlistId else { return }
            if id.hasPrefix("RD") { PlayerEngine.shared.playStation(playlistId: id, title: card.title); pushNowPlaying(); return }
            let page = try? await YTM.shared.playlist(id: id)
            pushTrackList(title: card.title, tracks: page?.tracks ?? [])
        case .album:
            guard let id = card.browseId else { return }
            let page = try? await YTM.shared.album(browseId: id)
            pushTrackList(title: card.title, tracks: page?.tracks ?? [])
        case .station:
            if let id = card.playlistId { PlayerEngine.shared.playStation(playlistId: id, title: card.title); pushNowPlaying() }
        default:
            break
        }
    }

    @MainActor
    private func pushTrackList(title: String, tracks: [Track]) {
        let items = tracks.enumerated().map { idx, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artistLine)
            setArtwork(item, url: track.thumbnailURL)
            item.handler = { [weak self] _, completion in
                PlayerEngine.shared.playCollection(tracks, startAt: idx)
                self?.pushNowPlaying(); completion()
            }
            return item
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    @MainActor
    private func pushNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        if interfaceController?.topTemplate !== np {
            interfaceController?.pushTemplate(np, animated: true, completion: nil)
        }
    }

    private func syncNowPlaying() {
        // The system Now Playing template reads MPNowPlayingInfoCenter, which
        // the engine already updates; nothing else required here.
    }

    private func setArtwork(_ item: CPListItem, url: URL?) {
        guard let url = Artwork.upscale(url, to: 200) else { return }
        Task.detached {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run { item.setImage(image) }
        }
    }
}
