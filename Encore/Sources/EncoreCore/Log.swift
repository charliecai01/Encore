import os

/// Lightweight unified-logging facade for diagnostics that can stay in the build
/// (negligible overhead, filterable, redaction-aware). Stream live from a paired
/// device or the Mac app:
///
///   log stream --predicate 'subsystem == "dev.charlie.encore"' --info
///   log stream --device --predicate 'subsystem == "dev.charlie.encore"' --info
///
/// or filter by the subsystem in Console.app. Categories keep noise filterable;
/// add more as new areas need tracing.
public enum Log {
    private static let subsystem = "dev.charlie.encore"

    /// Playback-engine lifecycle: session restore, first play, web-player
    /// engage decisions, state transitions, queue advance.
    public static let player = Logger(subsystem: subsystem, category: "player")
    /// InnerTube networking (reserved for future tracing).
    public static let net = Logger(subsystem: subsystem, category: "net")
}
