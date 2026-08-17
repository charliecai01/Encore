// Smoke test: exercises the InnerTube client and parsers against live
// YouTube Music (unauthenticated). Run with `swift run encore-smoke`.
import Foundation
import EncoreCore

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
}

let ytm = YTM.shared

Task {
    // Search (all)
    do {
        let results = try await ytm.search("daft punk", filter: nil)
        let trackCount = results.shelves.flatMap(\.tracks).count
        check("search all", !results.shelves.isEmpty,
              "top=\(results.top != nil), shelves=\(results.shelves.count), tracks=\(trackCount)")
    } catch { check("search all", false, "\(error)") }

    // Search filtered: songs
    var firstSong: Track?
    do {
        let results = try await ytm.search("get lucky", filter: .songs)
        let tracks = results.shelves.flatMap(\.tracks)
        firstSong = tracks.first
        check("search songs", !tracks.isEmpty,
              tracks.prefix(2).map { "\($0.title) – \($0.artistLine) [\($0.durationText)]" }.joined(separator: " | "))
    } catch { check("search songs", false, "\(error)") }

    // Search filtered: albums + album page
    do {
        let results = try await ytm.search("random access memories", filter: .albums)
        let cards = results.shelves.flatMap(\.items).compactMap { item -> CardItem? in
            if case .card(let c) = item, c.kind == .album { return c }
            return nil
        }
        check("search albums", !cards.isEmpty, cards.first.map { "\($0.title) (\($0.browseId ?? "?"))" } ?? "")
        if let browseId = cards.first?.browseId {
            let page = try await ytm.album(browseId: browseId)
            check("album page", !page.tracks.isEmpty && !page.title.isEmpty,
                  "\(page.title): \(page.tracks.count) tracks, subtitle=\(page.subtitle)")
        }
    } catch { check("album", false, "\(error)") }

    // Artist page
    do {
        let results = try await ytm.search("tame impala", filter: .artists)
        var artistId: String?
        for shelf in results.shelves {
            for item in shelf.items {
                if case .card(let c) = item, c.kind == .artist { artistId = c.browseId; break }
            }
        }
        if case .card(let c)? = results.top, c.kind == .artist { artistId = artistId ?? c.browseId }
        if let artistId {
            let page = try await ytm.artist(browseId: artistId)
            check("artist page", !page.name.isEmpty && !page.shelves.isEmpty,
                  "\(page.name): \(page.shelves.count) shelves, radio=\(page.radioPlaylistId != nil)")
        } else {
            check("artist page", false, "no artist card found")
        }
    } catch { check("artist page", false, "\(error)") }

    // Queue / radio
    if let song = firstSong {
        do {
            let q = try await ytm.radioQueue(for: song.videoId)
            check("radio queue", q.tracks.count > 5,
                  "\(q.tracks.count) tracks, lyricsBrowseId=\(q.lyricsBrowseId ?? "nil")")
        } catch { check("radio queue", false, "\(error)") }

        // Lyrics — auto chain and each new provider directly
        let lyrics = await LyricsService.shared.lyrics(for: song)
        check("lyrics auto", lyrics != nil,
              "source=\(lyrics?.source.rawValue ?? "none"), synced=\(lyrics?.lines?.count ?? 0) lines, plain=\(lyrics?.plain != nil)")

        let netease = await NetEase.fetch(track: song)
        check("lyrics netease", netease != nil, "synced=\(netease?.lines?.count ?? 0) lines")
        let mxm = await Musixmatch.fetch(track: song)
        check("lyrics musixmatch", mxm != nil,
              "synced=\(mxm?.lines?.count ?? 0) lines, plain=\(mxm?.plain != nil) (best-effort: may be rate-limited)")
        let genius = await Genius.fetch(track: song)
        check("lyrics genius", genius != nil, "plain=\(genius?.plain?.count ?? 0) chars")
    }

    // Large playlist pagination — must fetch far past the first page
    do {
        let results = try await ytm.search("longest playlist 500 songs", filter: .playlists)
        var candidate: CardItem?
        for shelf in results.shelves {
            for item in shelf.items {
                if case .card(let c) = item, c.kind == .playlist, c.playlistId != nil {
                    candidate = c
                    break
                }
            }
            if candidate != nil { break }
        }
        if let candidate, let id = candidate.playlistId {
            let page = try await ytm.playlist(id: id)
            check("large playlist", page.tracks.count > 150,
                  "\(candidate.title): parsed \(page.tracks.count) tracks (declared: \(page.secondSubtitle))")
        } else {
            check("large playlist", false, "no playlist found in search")
        }
    } catch { check("large playlist", false, "\(error)") }

    // Simplified Chinese query must surface Traditional-listed artists
    do {
        let results = try await ytm.search("周杰伦", filter: nil)
        var found = false
        var sample: [String] = []
        for shelf in results.shelves {
            for item in shelf.items {
                let name: String
                switch item {
                case .track(let t): name = t.title + " " + t.artistLine
                case .card(let c): name = c.title + " " + c.subtitle
                }
                if sample.count < 3 { sample.append(name) }
                if name.contains("周杰倫") || name.contains("周杰伦") { found = true }
            }
        }
        if case .card(let c)? = results.top, c.title.contains("周杰") { found = true }
        check("CJK search", found, "items: \(sample.joined(separator: " | "))")
    } catch { check("CJK search", false, "\(error)") }

    // Suggestions
    do {
        let s = try await ytm.suggestions("billie ei")
        check("suggestions", !s.isEmpty, s.prefix(3).joined(separator: ", "))
    } catch { check("suggestions", false, "\(error)") }

    // Home (unauthenticated — may be generic but should parse)
    do {
        let shelves = try await ytm.home()
        check("home", true, "\(shelves.count) shelves: \(shelves.prefix(3).map(\.title).joined(separator: ", "))")
    } catch { check("home", false, "\(error)") }

    // Podcasts feed + show page
    do {
        let shelves = try await ytm.podcasts()
        let shows = shelves.flatMap(\.items).compactMap { item -> CardItem? in
            if case .card(let c) = item, c.kind == .podcast { return c }
            return nil
        }
        check("podcasts feed", !shows.isEmpty,
              "\(shelves.count) shelves, \(shows.count) podcast shows; e.g. \(shows.first?.title ?? "")")
        if let showId = shows.first?.browseId {
            let page = try await ytm.podcastShow(browseId: showId)
            check("podcast show", !page.tracks.isEmpty,
                  "\(page.title): \(page.tracks.count) episodes; first=\(page.tracks.first?.title ?? "")")
        }
    } catch { check("podcasts", false, "\(error)") }

    // Native artist names: CJK artists must resolve to a Simplified name,
    // English ones must resolve to nothing (and never to somebody else's).
    for name in ["Jacky Cheung", "Chang Hui Mei", "JJ Lin", "Leehom Wang", "Ronghao Li", "Sun Yanzi", "Taylor Swift", "Jackson Whalan"] {
        let native = await NativeNames.native(for: name)
        let expectsNative = !["Taylor Swift", "Jackson Whalan"].contains(name)
        check("native name: \(name)", expectsNative == (native != nil),
              native ?? "(none — not a CJK artist)")
    }

    exit(0)
}

RunLoop.main.run()
