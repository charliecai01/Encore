import Foundation

/// One band member: display name plus an optional role ("vocals", "guitar").
public struct BandMember: Equatable {
    public var name: String
    public var role: String?
    public init(name: String, role: String? = nil) { self.name = name; self.role = role }
}

/// Structured facts about an artist, resolved from Wikidata. For a band, the
/// "birth" fields carry formation place/year and `deathYear` the disband year.
public struct ArtistFacts: Equatable {
    public var isBand = false
    public var birthplace: String?      // person: birthplace · band: formation place
    public var birthYear: Int?          // person: born · band: formed (inception)
    public var birthMonth: Int?
    public var birthDay: Int?
    public var deathYear: Int?          // person: died · band: dissolved
    public var country: String?         // citizenship / country of origin
    public var careerStartYear: Int?    // work-period start (falls back to inception)
    public var members: [BandMember] = []

    public init() {}
}

/// Resolves a short factual bio for an artist page — birthplace, age, country,
/// career start, and (for bands) the members — from Wikidata's free API.
/// Network results are cached per name for the session; `compose` is pure and
/// unit-tested.
public enum ArtistInfo {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]   // name -> summary ("" = known miss)

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public entry

    /// The summary paragraph for an artist-page name, or nil when the artist
    /// can't be resolved. Safe to call repeatedly (cached, including misses).
    public static func summary(forName rawName: String, now: Date = Date()) async -> String? {
        let key = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit.isEmpty ? nil : hit }
        lock.unlock()

        var summary: String?
        for candidate in candidates(from: rawName) {
            guard let id = await searchEntity(candidate) else { continue }
            guard let facts = await fetchFacts(id: id) else { continue }
            if let s = compose(name: candidate, facts: facts, now: now) {
                summary = s
                break
            }
        }
        lock.lock(); cache[key] = summary ?? ""; lock.unlock()
        return summary
    }

    // MARK: - Name handling

    /// YT artist pages often combine names ("陶喆 - David Tao"); each half is a
    /// far better Wikidata query than the combined string, so try parts first.
    static func candidates(from raw: String) -> [String] {
        let full = raw.trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        for sep in [" - ", " – ", " — ", " · "] where full.contains(sep) {
            for part in full.components(separatedBy: sep) {
                let t = part.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !out.contains(t) { out.append(t) }
            }
            break
        }
        if !out.contains(full) { out.append(full) }
        return out
    }

    // MARK: - Composition (pure)

    /// Build the summary sentences per the spec: birthplace, age, country most
    /// active in, when they entered the scene — plus, for bands, who the
    /// members are (with roles when known).
    public static func compose(name: String, facts: ArtistFacts, now: Date = Date()) -> String? {
        var s: [String] = []
        let verb = facts.isBand ? "was formed" : "was born"

        if let place = facts.birthplace {
            if let c = facts.country, c != place {
                s.append("\(name) \(verb) in \(place), \(c).")
            } else {
                s.append("\(name) \(verb) in \(place).")
            }
        }

        if let y = facts.birthYear {
            if facts.isBand {
                if let dis = facts.deathYear {
                    s.append("The band was formed in \(y) and disbanded in \(dis).")
                } else if let a = age(year: y, month: facts.birthMonth, day: facts.birthDay, now: now) {
                    s.append("The band is \(a) years old, formed in \(y).")
                }
            } else if let died = facts.deathYear {
                s.append("They passed away in \(died), at around \(max(0, died - y)) years old.")
            } else if let a = age(year: y, month: facts.birthMonth, day: facts.birthDay, now: now) {
                if let m = facts.birthMonth, let d = facts.birthDay {
                    s.append("They are \(a) years old, born \(monthName(m)) \(d), \(y).")
                } else {
                    s.append("They are about \(a) years old, born in \(y).")
                }
            }
        }

        if let c = facts.country {
            s.append(facts.deathYear == nil ? "They are most active in \(c)."
                                            : "They were most active in \(c).")
        }

        // Skip the career sentence when it would just repeat the band's
        // formation year from sentence two.
        if let start = facts.careerStartYear,
           !(facts.isBand && facts.birthYear == start) {
            s.append("They first entered the scene in \(start).")
        }

        if facts.isBand, !facts.members.isEmpty {
            let parts = facts.members.map { m in
                m.role.map { "\(m.name) (\($0))" } ?? m.name
            }
            s.append("The members are \(joined(parts)).")
        }

        return s.isEmpty ? nil : s.joined(separator: " ")
    }

    static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }

    static func age(year: Int, month: Int?, day: Int?, now: Date) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: now)
        guard let ny = c.year else { return nil }
        var a = ny - year
        if let m = month, let nm = c.month {
            if nm < m || (nm == m && (c.day ?? 1) < (day ?? 1)) { a -= 1 }
        }
        return (0...120).contains(a) ? a : nil
    }

    static func monthName(_ m: Int) -> String {
        let names = ["January", "February", "March", "April", "May", "June", "July",
                     "August", "September", "October", "November", "December"]
        return (1...12).contains(m) ? names[m - 1] : "\(m)"
    }

    /// "+1969-07-11T00:00:00Z" → (1969, 7, 11); month/day nil when Wikidata's
    /// precision leaves them as 00.
    static func parseTime(_ s: String) -> (year: Int, month: Int?, day: Int?)? {
        let t = s.hasPrefix("+") ? String(s.dropFirst()) : s
        let date = t.prefix(while: { $0 != "T" })
        let parts = date.split(separator: "-")
        guard let y = Int(parts.first ?? "") else { return nil }
        let m = parts.count > 1 ? Int(parts[1]) : nil
        let d = parts.count > 2 ? Int(parts[2]) : nil
        return (y, (m ?? 0) == 0 ? nil : m, (d ?? 0) == 0 ? nil : d)
    }

    /// Instrument/occupation labels → the short role words people expect.
    static func prettyRole(_ raw: String) -> String {
        switch raw.lowercased() {
        case "voice", "singing", "vocal music": return "vocals"
        case "drum kit", "drum", "drums": return "drums"
        case "bass guitar", "double bass": return "bass"
        case "electric guitar", "acoustic guitar": return "guitar"
        case "keyboard instrument", "keyboards", "piano": return "keyboards"
        default: return raw.lowercased()
        }
    }

    // MARK: - Wikidata plumbing

    private static func api(_ params: [String: String]) async -> JSONValue? {
        var comps = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Encore/1.0 (personal music player)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return JSONValue.parse(data)
    }

    /// Find the Wikidata entity for a name, requiring a music-flavored
    /// description so we never attach a random namesake's bio.
    static func searchEntity(_ query: String) async -> String? {
        let lang = CJK.hasHan(query) ? "zh" : "en"
        guard let json = await api([
            "action": "wbsearchentities", "format": "json", "type": "item",
            "language": lang, "uselang": "en", "limit": "5", "search": query,
        ]) else { return nil }
        guard let results = json["search"].array else { return nil }
        let musicWords = ["singer", "musician", "songwriter", "rapper", "band",
                          "musical group", "music group", "musical ensemble",
                          "composer", "vocalist", "music duo", "idol", "boy band",
                          "girl group", "musical artist", "recording artist"]
        for r in results {
            let desc = (r["description"].string ?? "").lowercased()
            if musicWords.contains(where: { desc.contains($0) }) {
                return r["id"].string
            }
        }
        return nil
    }

    static func fetchFacts(id: String) async -> ArtistFacts? {
        guard let json = await api([
            "action": "wbgetentities", "format": "json", "ids": id, "props": "claims",
        ]) else { return nil }
        let claims = json["entities"][id]["claims"]
        guard claims.exists else { return nil }

        var facts = ArtistFacts()
        let instanceOf = entityIds(claims, "P31")
        let isHuman = instanceOf.contains("Q5")

        if let t = firstTime(claims, "P569") ?? (isHuman ? nil : firstTime(claims, "P571")) {
            facts.birthYear = t.year; facts.birthMonth = t.month; facts.birthDay = t.day
        }
        if let t = firstTime(claims, isHuman ? "P570" : "P576") { facts.deathYear = t.year }
        if let t = firstTime(claims, "P2031") {
            facts.careerStartYear = t.year
        } else if !isHuman, let t = firstTime(claims, "P571") {
            facts.careerStartYear = t.year
        }

        let placeId = firstEntityId(claims, "P19") ?? firstEntityId(claims, "P740")
        let countryId = firstEntityId(claims, "P27") ?? firstEntityId(claims, "P495")

        if !isHuman {
            let memberIds = entityIds(claims, "P527")
            if !memberIds.isEmpty {
                facts.isBand = true
                facts.members = await fetchMembers(Array(memberIds.prefix(8)))
            }
        }

        let toResolve = [placeId, countryId].compactMap { $0 }
        if !toResolve.isEmpty {
            let labels = await fetchLabels(ids: toResolve)
            if let p = placeId { facts.birthplace = labels[p] }
            if let c = countryId { facts.country = labels[c] }
        }
        return facts
    }

    /// Names + roles for band members: one batched call for the members
    /// (labels + instrument/occupation claims), one for the role labels.
    static func fetchMembers(_ ids: [String]) async -> [BandMember] {
        guard !ids.isEmpty,
              let json = await api([
                  "action": "wbgetentities", "format": "json",
                  "ids": ids.joined(separator: "|"),
                  "props": "labels|claims", "languages": "en",
              ]) else { return [] }
        var partial: [(name: String, roleId: String?)] = []
        var roleIds: [String] = []
        for id in ids {
            let entity = json["entities"][id]
            guard let name = entity["labels"]["en"]["value"].string else { continue }
            let claims = entity["claims"]
            let roleId = firstEntityId(claims, "P1303") ?? firstEntityId(claims, "P106")
            if let roleId, !roleIds.contains(roleId) { roleIds.append(roleId) }
            partial.append((name, roleId))
        }
        var roleLabels: [String: String] = [:]
        if !roleIds.isEmpty { roleLabels = await fetchLabels(ids: roleIds) }
        return partial.map { p in
            BandMember(name: p.name,
                       role: p.roleId.flatMap { roleLabels[$0] }.map(prettyRole))
        }
    }

    static func fetchLabels(ids: [String]) async -> [String: String] {
        guard !ids.isEmpty,
              let json = await api([
                  "action": "wbgetentities", "format": "json",
                  "ids": ids.joined(separator: "|"),
                  "props": "labels", "languages": "en",
              ]) else { return [:] }
        var out: [String: String] = [:]
        for id in ids {
            if let label = json["entities"][id]["labels"]["en"]["value"].string {
                out[id] = label
            }
        }
        return out
    }

    // MARK: - Claim helpers

    private static func firstTime(_ claims: JSONValue, _ property: String)
        -> (year: Int, month: Int?, day: Int?)? {
        guard let raw = claims[property][0]["mainsnak"]["datavalue"]["value"]["time"].string
        else { return nil }
        return parseTime(raw)
    }

    private static func firstEntityId(_ claims: JSONValue, _ property: String) -> String? {
        claims[property][0]["mainsnak"]["datavalue"]["value"]["id"].string
    }

    private static func entityIds(_ claims: JSONValue, _ property: String) -> [String] {
        (claims[property].array ?? []).compactMap {
            $0["mainsnak"]["datavalue"]["value"]["id"].string
        }
    }
}
