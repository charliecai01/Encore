import Foundation

extension YTM {

    /// Searches the query as typed; for Simplified Chinese input, also
    /// searches the Traditional form and merges (Taiwanese artists are listed
    /// in Traditional and YouTube doesn't always bridge the scripts).
    public func search(_ query: String, filter: SearchFilter?) async throws -> SearchResults {
        guard let variant = CJK.toTraditional(query) else {
            return try await searchRaw(query, filter: filter)
        }
        async let primaryTask = searchRaw(query, filter: filter)
        async let variantTask = try? searchRaw(variant, filter: filter)
        let primary = try await primaryTask
        guard let secondary = await variantTask else { return primary }
        return merged(primary, secondary)
    }

    private func searchRaw(_ query: String, filter: SearchFilter?) async throws -> SearchResults {
        var body: [String: Any] = ["query": query]
        if let filter { body["params"] = filter.params }
        let r = try await net.post("search", body: body)
        return P.searchResults(from: r)
    }

    private func merged(_ a: SearchResults, _ b: SearchResults) -> SearchResults {
        var out = a
        if out.top == nil { out.top = b.top }

        var seen = Set<String>()
        func key(_ item: ShelfItem) -> String {
            switch item {
            case .track(let t): return "t:" + t.videoId
            case .card(let c): return "c:" + c.id
            }
        }
        for shelf in out.shelves {
            for item in shelf.items { seen.insert(key(item)) }
        }
        if let top = out.top { seen.insert(key(top)) }

        for shelf in b.shelves {
            let fresh = shelf.items.filter { seen.insert(key($0)).inserted }
            guard !fresh.isEmpty else { continue }
            if let idx = out.shelves.firstIndex(where: { $0.title == shelf.title }) {
                out.shelves[idx].items.append(contentsOf: fresh)
            } else {
                out.shelves.append(Shelf(title: shelf.title, items: fresh))
            }
        }
        return out
    }

    public func suggestions(_ input: String) async throws -> [String] {
        let r = try await net.post("music/get_search_suggestions", body: ["input": input])
        var results = P.suggestions(from: r)
        if let variant = CJK.toTraditional(input), !results.contains(variant) {
            results.insert(variant, at: 0)
        }
        return results
    }
}
