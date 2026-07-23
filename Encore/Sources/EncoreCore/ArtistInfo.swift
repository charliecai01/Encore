import Foundation

/// One band member: display name plus an optional role ("vocals", "guitar").
public struct BandMember: Equatable {
    public var name: String
    public var role: String?
    public init(name: String, role: String? = nil) { self.name = name; self.role = role }
}

/// Pronoun set derived from Wikidata's recorded gender (P21). `unspecified`
/// (no/unmapped P21) falls back to they/them — never guessed from the name.
public enum ArtistGender: Equatable {
    case male, female, unspecified

    var subject: String {
        switch self { case .male: return "He"; case .female: return "She"; case .unspecified: return "They" }
    }
    var possessive: String {
        switch self { case .male: return "His"; case .female: return "Her"; case .unspecified: return "Their" }
    }
    var isPlural: Bool { self == .unspecified }
}

/// Structured facts about an artist, resolved from Wikidata. For a band, the
/// "birth" fields carry formation place/year and `deathYear` the disband year.
public struct ArtistFacts: Equatable {
    public var isBand = false
    public var gender: ArtistGender = .unspecified
    public var birthplace: String?      // person: birthplace · band: formation place
    public var birthYear: Int?          // person: born · band: formed (inception)
    public var birthMonth: Int?
    public var birthDay: Int?
    public var deathYear: Int?          // person: died · band: dissolved
    public var country: String?         // citizenship / country of origin
    public var careerStartYear: Int?    // work-period start (falls back to inception)
    public var members: [BandMember] = []
    /// "What they're known for" — sentences from the Wikipedia lede when
    /// available; compose() falls back to occupations/genres otherwise.
    public var knownFor: [String] = []
    public var occupations: [String] = []
    public var genres: [String] = []
    public var wikiTitle: String?       // enwiki sitelink, for the lede fetch

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
            guard var facts = await fetchFacts(id: id) else { continue }
            if let title = facts.wikiTitle {
                facts.knownFor = await fetchKnownFor(wikiTitle: title)
            }
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
    /// active in, when they entered the scene, two "known for" sentences —
    /// plus, for bands, who the members are (with roles when known). Pronouns
    /// come from Wikidata's recorded gender; they/them when unrecorded.
    public static func compose(name: String, facts: ArtistFacts, now: Date = Date()) -> String? {
        var s: [String] = []
        let verb = facts.isBand ? "was formed" : "was born"
        let gender: ArtistGender = facts.isBand ? .unspecified : facts.gender
        let subject = gender.subject
        let copula = gender.isPlural ? "are" : "is"
        let pastCopula = gender.isPlural ? "were" : "was"

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
                s.append("\(subject) passed away in \(died), at around \(max(0, died - y)) years old.")
            } else if let a = age(year: y, month: facts.birthMonth, day: facts.birthDay, now: now) {
                if let m = facts.birthMonth, let d = facts.birthDay {
                    s.append("\(subject) \(copula) \(a) years old, born \(monthName(m)) \(d), \(y).")
                } else {
                    s.append("\(subject) \(copula) about \(a) years old, born in \(y).")
                }
            }
        }

        if let c = facts.country {
            s.append(facts.deathYear == nil ? "\(subject) \(copula) most active in \(c)."
                                            : "\(subject) \(pastCopula) most active in \(c).")
        }

        // Skip the career sentence when it would just repeat the band's
        // formation year from sentence two.
        if let start = facts.careerStartYear,
           !(facts.isBand && facts.birthYear == start) {
            s.append("\(subject) first entered the scene in \(start).")
        }

        // What they're known for: the Wikipedia lede when available, else a
        // structured occupations/genres fallback.
        if !facts.knownFor.isEmpty {
            s.append(contentsOf: facts.knownFor.prefix(2))
        } else {
            if !facts.occupations.isEmpty {
                let occ = joined(Array(facts.occupations.prefix(3)))
                let article = "aeiou".contains(occ.lowercased().first ?? "x") ? "an" : "a"
                s.append(facts.deathYear == nil
                         ? "\(subject) \(copula) best known as \(article) \(occ)."
                         : "\(subject) \(pastCopula) best known as \(article) \(occ).")
            }
            if !facts.genres.isEmpty {
                s.append("\(gender.possessive) music spans \(joined(Array(facts.genres.prefix(3)))).")
            }
        }

        if facts.isBand, !facts.members.isEmpty {
            let parts = facts.members.map { m in
                m.role.map { "\(m.name) (\($0))" } ?? m.name
            }
            s.append("The members are \(joined(parts)).")
        }

        return s.isEmpty ? nil : s.joined(separator: " ")
    }

    /// First `limit` sentences of a Wikipedia lede, with parentheticals (birth
    /// dates, pinyin, IPA) stripped. Pure; the splitter protects initials.
    static func knownForSentences(from extract: String, limit: Int = 2) -> [String] {
        var text = extract.replacingOccurrences(of: #"\s*\([^()]*\)"#, with: "",
                                                options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ",
                                         options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            current.append(ch)
            if ".!?".contains(ch), i + 1 < chars.count, chars[i + 1] == " " {
                let next = i + 2 < chars.count ? chars[i + 2] : " "
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                // Don't split after an initial ("R." in "R. Kelly") or common titles.
                let lastWord = trimmed.split(separator: " ").last.map(String.init) ?? ""
                let isInitial = lastWord.count == 2 && lastWord.hasSuffix(".")
                    && lastWord.first!.isUppercase
                let isTitle = ["Mr.", "Mrs.", "Dr.", "St.", "Jr.", "Sr."].contains(lastWord)
                if next.isUppercase || next.isNumber, !isInitial, !isTitle {
                    sentences.append(trimmed)
                    current = ""
                    i += 2
                    continue
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return Array(sentences.prefix(limit))
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
            "action": "wbgetentities", "format": "json", "ids": id,
            "props": "claims|sitelinks",
        ]) else { return nil }
        let claims = json["entities"][id]["claims"]
        guard claims.exists else { return nil }

        var facts = ArtistFacts()
        facts.wikiTitle = json["entities"][id]["sitelinks"]["enwiki"]["title"].string
        let instanceOf = entityIds(claims, "P31")
        let isHuman = instanceOf.contains("Q5")

        // Recorded gender (P21) → pronouns; unmapped values stay they/them.
        switch firstEntityId(claims, "P21") {
        case "Q6581097", "Q2449503": facts.gender = .male    // male, trans man
        case "Q6581072", "Q1052281": facts.gender = .female  // female, trans woman
        default: facts.gender = .unspecified
        }

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
        let occupationIds = Array(entityIds(claims, "P106").prefix(3))
        let genreIds = Array(entityIds(claims, "P136").prefix(3))

        if !isHuman {
            let memberIds = entityIds(claims, "P527")
            if !memberIds.isEmpty {
                facts.isBand = true
                facts.members = await fetchMembers(Array(memberIds.prefix(8)))
            }
        }

        let toResolve = ([placeId, countryId].compactMap { $0 }) + occupationIds + genreIds
        if !toResolve.isEmpty {
            let labels = await fetchLabels(ids: toResolve)
            if let p = placeId { facts.birthplace = labels[p] }
            if let c = countryId { facts.country = labels[c] }
            facts.occupations = occupationIds.compactMap { labels[$0] }
            facts.genres = genreIds.compactMap { labels[$0] }
        }
        return facts
    }

    /// First sentences of the English Wikipedia lede for a sitelinked title.
    static func fetchKnownFor(wikiTitle: String) async -> [String] {
        let path = wikiTitle.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? wikiTitle
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)")
        else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Encore/1.0 (personal music player)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let extract = JSONValue.parse(data)["extract"].string else { return [] }
        return knownForSentences(from: extract, limit: 2)
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
