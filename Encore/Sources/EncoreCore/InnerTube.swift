import Foundation
import CryptoKit

public enum YTClient {
    case webRemix
    case androidMusic

    var contextClient: [String: Any] {
        switch self {
        case .webRemix:
            return [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20250602.03.00",
                "hl": "en",
                "gl": "US",
            ]
        case .androidMusic:
            return [
                "clientName": "ANDROID_MUSIC",
                "clientVersion": "7.21.50",
                "androidSdkVersion": 34,
                "hl": "en",
                "gl": "US",
            ]
        }
    }

    var userAgent: String {
        switch self {
        case .webRemix:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        case .androidMusic:
            return "com.google.android.apps.youtube.music/7.21.50 (Linux; U; Android 14) gzip"
        }
    }
}

public enum InnerTubeError: LocalizedError {
    case badStatus(Int, String)
    case notSignedIn

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            return "YouTube Music returned HTTP \(code). \(body)"
        case .notSignedIn:
            return "This requires signing in to YouTube Music."
        }
    }
}

/// Low-level client for YouTube Music's InnerTube API, authenticated with the
/// browser cookies captured by the in-app Google sign-in.
public final class InnerTube: @unchecked Sendable {
    public static let shared = InnerTube()

    private let session: URLSession
    private let origin = "https://music.youtube.com"
    private let lock = NSLock()
    private var _cookieHeader: String?

    public var cookieHeader: String? {
        get { lock.lock(); defer { lock.unlock() }; return _cookieHeader }
        set { lock.lock(); defer { lock.unlock() }; _cookieHeader = newValue }
    }

    public var isAuthenticated: Bool { sapisid != nil }

    private var sapisid: String? {
        guard let header = cookieHeader else { return nil }
        var found: [String: String] = [:]
        for part in header.components(separatedBy: "; ") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            found[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return found["SAPISID"] ?? found["__Secure-3PAPISID"]
    }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    public func post(_ endpoint: String, body: [String: Any],
                     client: YTClient = .webRemix,
                     query: [String: String] = [:]) async throws -> JSONValue {
        var comps = URLComponents(string: "https://music.youtube.com/youtubei/v1/\(endpoint)")!
        var items = [URLQueryItem(name: "prettyPrint", value: "false")]
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items

        var payload = body
        payload["context"] = ["client": client.contextClient]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin, forHTTPHeaderField: "X-Origin")

        if let cookies = cookieHeader {
            req.setValue(cookies, forHTTPHeaderField: "Cookie")
            if let sid = sapisid {
                req.setValue(authorization(sapisid: sid), forHTTPHeaderField: "Authorization")
                req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            }
        }

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw InnerTubeError.badStatus(status, snippet)
        }
        return JSONValue.parse(data)
    }

    private func authorization(sapisid: String) -> String {
        let t = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(t) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(t)_\(hex)"
    }
}
