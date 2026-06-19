import XCTest
@testable import EncoreCore

/// URLProtocol that returns a queued sequence of canned responses, so the
/// networking layer can be tested deterministically without hitting the network.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var data: Data = Data("{}".utf8)
        var error: URLError? = nil
    }

    private static let lock = NSLock()
    private static var stubs: [Stub] = []
    private static var _requestCount = 0
    private static var _lastHeaders: [String: String] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs = []; _requestCount = 0; _lastHeaders = [:]
    }
    static func enqueue(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(stub)
    }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }
    static var lastHeaders: [String: String] { lock.lock(); defer { lock.unlock() }; return _lastHeaders }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub = {
            MockURLProtocol.lock.lock(); defer { MockURLProtocol.lock.unlock() }
            MockURLProtocol._requestCount += 1
            MockURLProtocol._lastHeaders = request.allHTTPHeaderFields ?? [:]
            return MockURLProtocol.stubs.isEmpty ? Stub() : MockURLProtocol.stubs.removeFirst()
        }()
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeClient() -> InnerTube {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let net = InnerTube(session: URLSession(configuration: config))
    net.retryBaseDelay = 0 // don't actually sleep between retries in tests
    return net
}

final class InnerTubeRetryTests: XCTestCase {
    override func setUp() { super.setUp(); MockURLProtocol.reset() }

    func testSucceedsFirstTry() async throws {
        MockURLProtocol.enqueue(.init(status: 200, data: Data(#"{"ok":true}"#.utf8)))
        let r = try await makeClient().post("browse", body: [:])
        XCTAssertEqual(r["ok"].bool, true)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testRetriesOn503ThenSucceeds() async throws {
        MockURLProtocol.enqueue(.init(status: 503))
        MockURLProtocol.enqueue(.init(status: 200, data: Data(#"{"ok":1}"#.utf8)))
        _ = try await makeClient().post("browse", body: [:])
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testRetriesOnTransientNetworkErrorThenSucceeds() async throws {
        MockURLProtocol.enqueue(.init(error: URLError(.networkConnectionLost)))
        MockURLProtocol.enqueue(.init(status: 200))
        _ = try await makeClient().post("browse", body: [:])
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testGivesUpAfterMaxAttempts() async {
        for _ in 0..<5 { MockURLProtocol.enqueue(.init(status: 503)) }
        let net = makeClient()
        net.maxAttempts = 3
        do {
            _ = try await net.post("browse", body: [:])
            XCTFail("expected to throw after exhausting retries")
        } catch let InnerTubeError.badStatus(code, _) {
            XCTAssertEqual(code, 503)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testDoesNotRetryClientError() async {
        MockURLProtocol.enqueue(.init(status: 401))
        MockURLProtocol.enqueue(.init(status: 200))
        do {
            _ = try await makeClient().post("browse", body: [:])
            XCTFail("expected to throw on 401")
        } catch let InnerTubeError.badStatus(code, _) {
            XCTAssertEqual(code, 401)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testNonIdempotentNeverRetries() async {
        MockURLProtocol.enqueue(.init(status: 503))
        MockURLProtocol.enqueue(.init(status: 200))
        do {
            _ = try await makeClient().post("like/like", body: [:], idempotent: false)
            XCTFail("expected to throw — mutations must not be replayed")
        } catch let InnerTubeError.badStatus(code, _) {
            XCTAssertEqual(code, 503)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testDoesNotRetryWhenOffline() async {
        MockURLProtocol.enqueue(.init(error: URLError(.notConnectedToInternet)))
        MockURLProtocol.enqueue(.init(status: 200))
        do {
            _ = try await makeClient().post("browse", body: [:])
            XCTFail("expected to throw when offline")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .notConnectedToInternet)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testAuthHeaderAddedWhenSignedIn() async throws {
        MockURLProtocol.enqueue(.init(status: 200))
        let net = makeClient()
        net.cookieHeader = "SAPISID=secret123; SID=foo"
        XCTAssertTrue(net.isAuthenticated)
        _ = try await net.post("browse", body: [:])
        let auth = MockURLProtocol.lastHeaders["Authorization"]
        XCTAssertEqual(auth?.hasPrefix("SAPISIDHASH "), true, "expected SAPISIDHASH auth, got \(auth ?? "nil")")
        XCTAssertEqual(MockURLProtocol.lastHeaders["X-Goog-AuthUser"], "0")
    }

    func testNoAuthHeaderWhenSignedOut() async throws {
        MockURLProtocol.enqueue(.init(status: 200))
        let net = makeClient()
        XCTAssertFalse(net.isAuthenticated)
        _ = try await net.post("browse", body: [:])
        XCTAssertNil(MockURLProtocol.lastHeaders["Authorization"])
    }

    func testRetryClassification() {
        XCTAssertTrue(InnerTube.isRetryableStatus(503))
        XCTAssertTrue(InnerTube.isRetryableStatus(429))
        XCTAssertTrue(InnerTube.isRetryableStatus(500))
        XCTAssertFalse(InnerTube.isRetryableStatus(404))
        XCTAssertFalse(InnerTube.isRetryableStatus(401))
        XCTAssertFalse(InnerTube.isRetryableStatus(200))
        XCTAssertTrue(InnerTube.isTransient(URLError(.timedOut)))
        XCTAssertTrue(InnerTube.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(InnerTube.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(InnerTube.isTransient(URLError(.cancelled)))
    }
}

final class JSONValueTests: XCTestCase {
    func testParseValidNestedObject() {
        let v = JSONValue.parse(Data(#"{"a":{"b":[1,2,3]}}"#.utf8))
        XCTAssertEqual(v["a"]["b"][1].int, 2)
    }

    func testParseHTMLBodyReturnsNull() {
        // A captive portal / error page comes back as HTML, not JSON.
        let v = JSONValue.parse(Data("<html><body>error</body></html>".utf8))
        XCTAssertTrue(v.isNull)
    }

    func testParseEmptyDataReturnsNull() {
        XCTAssertTrue(JSONValue.parse(Data()).isNull)
    }

    func testIntLikeParsesStringEncodedNumbers() {
        let v = JSONValue.parse(Data(#"{"ms":"1700000000000"}"#.utf8))
        XCTAssertEqual(v["ms"].intLike, 1_700_000_000_000)
        XCTAssertNil(v["ms"].int, "strict int must not coerce a string")
    }

    func testBoolAndNumberAreDistinct() {
        let v = JSONValue.parse(Data(#"{"flag":true,"n":1}"#.utf8))
        XCTAssertEqual(v["flag"].bool, true)
        XCTAssertNil(v["n"].bool, "1 is a number, not a bool")
        XCTAssertEqual(v["n"].int, 1)
    }

    func testRunsTextJoins() {
        let v = JSONValue.parse(Data(#"{"runs":[{"text":"Hello "},{"text":"World"}]}"#.utf8))
        XCTAssertEqual(v.runsText, "Hello World")
    }

    func testMissingKeysChainToNullWithoutCrashing() {
        let v = JSONValue.parse(Data(#"{"a":1}"#.utf8))
        XCTAssertTrue(v["x"]["y"][3].isNull)
        XCTAssertNil(v["x"].string)
    }

    func testFindAllCollectsEveryMatch() {
        let v = JSONValue.parse(Data(#"{"a":{"id":"1"},"b":[{"id":"2"},{"id":"3"}]}"#.utf8))
        XCTAssertEqual(Set(v.findAll("id").compactMap { $0.string }), ["1", "2", "3"])
    }

    func testFindAllRespectsLimit() {
        let v = JSONValue.parse(Data(#"{"a":[{"id":"1"},{"id":"2"},{"id":"3"}]}"#.utf8))
        XCTAssertEqual(v.findAll("id", limit: 2).count, 2)
    }
}
