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

    /// Total attempts (1 initial + retries) for idempotent requests. A flaky
    /// connection or a transient 5xx/429 from YouTube shouldn't surface as an
    /// empty screen, so reads are retried with backoff.
    public var maxAttempts = 3
    /// Base delay for exponential backoff between retries (seconds). Set to 0
    /// in tests to avoid real sleeps.
    public var retryBaseDelay: TimeInterval = 0.5

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

    /// Designated initializer. Inject a custom session (e.g. a URLProtocol mock)
    /// to test the client without hitting the network.
    public init(session: URLSession) {
        self.session = session
    }

    private convenience init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        // On flaky cellular, wait for the connection to come back instead of
        // failing instantly — otherwise a brief blip drops the radio refill and
        // playback stops. Bounded by timeoutIntervalForResource above.
        config.waitsForConnectivity = true
        self.init(session: URLSession(configuration: config))
    }

    /// POST to an InnerTube endpoint. Idempotent reads (the default) are retried
    /// on transient network errors and retryable HTTP statuses; pass
    /// `idempotent: false` for mutations so they're never replayed.
    public func post(_ endpoint: String, body: [String: Any],
                     client: YTClient = .webRemix,
                     query: [String: String] = [:],
                     idempotent: Bool = true) async throws -> JSONValue {
        let attempts = idempotent ? max(1, maxAttempts) : 1
        var attempt = 0
        while true {
            attempt += 1
            do {
                // Rebuild per attempt so the SAPISIDHASH timestamp stays fresh.
                let req = try makeRequest(endpoint: endpoint, body: body, client: client, query: query)
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return JSONValue.parse(data) }
                if Self.isRetryableStatus(status), attempt < attempts {
                    try await sleepBeforeRetry(attempt)
                    continue
                }
                let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw InnerTubeError.badStatus(status, snippet)
            } catch let error as URLError where Self.isTransient(error) && attempt < attempts {
                try await sleepBeforeRetry(attempt)
                continue
            }
        }
    }

    private func makeRequest(endpoint: String, body: [String: Any],
                            client: YTClient, query: [String: String]) throws -> URLRequest {
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
        return req
    }

    /// 429 (rate limit) and 5xx (server) are worth retrying; 4xx auth/client
    /// errors are not (they won't fix themselves on replay).
    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// Transport-level errors that a retry can plausibly recover from. Excludes
    /// "offline" and "cancelled", where retrying just wastes time.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func sleepBeforeRetry(_ attempt: Int) async throws {
        guard retryBaseDelay > 0 else { return }
        let delay = retryBaseDelay * pow(2, Double(attempt - 1))
        let jittered = delay * Double.random(in: 0.8...1.2)
        try await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
    }

    private func authorization(sapisid: String) -> String {
        let t = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(t) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(t)_\(hex)"
    }
}
