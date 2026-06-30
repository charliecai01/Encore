import os
import Foundation

/// Lightweight diagnostics facade that can stay in the build (negligible cost).
/// Each message goes to the unified log (subsystem `dev.charlie.encore`, marked
/// public so it isn't redacted) and, in DEBUG builds, to stdout — so it surfaces
/// three ways:
///   • Console.app / `log show` filtered by subsystem
///   • `xcrun devicectl device process launch --console …` (captures stdout)
///   • the Xcode console
/// Categories keep the noise filterable; add more as new areas need tracing.
public struct LogCategory {
    private let logger: Logger
    private let tag: String

    init(_ category: String) {
        self.logger = Logger(subsystem: "dev.charlie.encore", category: category)
        self.tag = category
    }

    public func notice(_ message: @autoclosure () -> String) {
        let m = message()
        logger.notice("\(m, privacy: .public)")
        emit("[\(tag)] \(m)")
    }

    public func error(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .public)")
        emit("[\(tag)] ERROR: \(m)")
    }

    /// Mirror to stderr (unbuffered, unlike stdout under a pipe) so live captures
    /// via `devicectl … --console` and the Xcode console see it immediately.
    private func emit(_ line: String) {
        #if DEBUG
        FileHandle.standardError.write(Data((line + "\n").utf8))
        #endif
    }
}

public enum Log {
    /// Playback-engine lifecycle: session restore, first play, web-player engage
    /// decisions, state transitions, queue advance.
    public static let player = LogCategory("player")
    /// InnerTube networking (reserved for future tracing).
    public static let net = LogCategory("net")
}
