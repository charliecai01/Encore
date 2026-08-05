import Foundation

/// Resolves a real account cookie for the live signed-in tests. Shared by
/// `AuthenticatedLiveTests` and `HealthSweepTests` so there's exactly one
/// lookup order to keep in sync.
///
/// The cookie is looked up at RUNTIME and never ships in the repo:
///   1. the ENCORE_TEST_COOKIE environment variable, if set
///   2. the local (skip-worktree'd) iOS/Sources/DevCredentials.swift
/// Returns nil when neither is available, so callers can XCTSkip and leave CI
/// and fresh checkouts green.
enum TestCookie {

    static func resolve() -> String? {
        if let env = ProcessInfo.processInfo.environment["ENCORE_TEST_COOKIE"],
           !env.isEmpty { return env }
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/EncoreCoreTests/TestCookie.swift
            .deletingLastPathComponent()            // Tests/EncoreCoreTests
            .deletingLastPathComponent()            // Tests
            .deletingLastPathComponent()            // Encore
            .appendingPathComponent("iOS/Sources/DevCredentials.swift")
        guard let src = try? String(contentsOf: url, encoding: .utf8),
              let open = src.range(of: "static let cookie = \""),
              let close = src.range(of: "\"", range: open.upperBound..<src.endIndex)
        else { return nil }
        let cookie = String(src[open.upperBound..<close.lowerBound])
        return cookie.isEmpty ? nil : cookie
    }
}
