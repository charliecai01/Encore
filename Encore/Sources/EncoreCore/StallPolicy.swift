import Foundation

/// What to do about a playback position that has stopped advancing.
public enum StallAction: Equatable {
    /// Leave it alone — it's either fine or already recovering.
    case none
    /// Cheap kick: ask the media element to play again. Keeps the buffer.
    case nudge
    /// Expensive: re-establish the stream. THROWS AWAY the buffer.
    case reload
}

/// Decides how the iOS engine reacts to a frozen playback position.
///
/// The rule that matters on weak cellular: **a buffering player is making
/// progress.** Reloading it restarts the download from nothing, so on a slow
/// link — where re-buffering takes longer than the stall threshold — a fixed
/// "frozen for N seconds → reload" rule turns one recoverable stall into an
/// endless reload loop that never plays a note. On wifi the reload finishes
/// instantly and the bug is invisible, which is why this only ever showed up
/// on cell.
///
/// So: never reload while the player reports buffering (up to a long escape
/// hatch for a genuinely wedged stream), and back off exponentially after each
/// reload that didn't help, instead of hammering at a fixed interval.
public enum StallPolicy {

    /// A short freeze usually just needs the element kicked.
    public static let nudgeAfter: TimeInterval = 4
    /// First reload threshold for a player that is NOT buffering.
    public static let baseReloadAfter: TimeInterval = 9
    /// Ceiling for the exponential backoff.
    public static let maxReloadAfter: TimeInterval = 60
    /// Escape hatch: a player that claims to be buffering this long is wedged,
    /// not slow. Generous, because on a bad link buffering really can take
    /// tens of seconds and waiting still beats restarting the download.
    public static let bufferingReloadAfter: TimeInterval = 45

    /// - Parameters:
    ///   - frozen: seconds since the playback position last advanced.
    ///   - buffering: the player reports it is actively buffering (YT state 3).
    ///   - consecutiveReloads: stall reloads since playback last really
    ///     progressed. Reset to 0 the moment the position moves again.
    ///   - alreadyNudged: a nudge was already sent for this stall.
    public static func action(frozen: TimeInterval,
                              buffering: Bool,
                              consecutiveReloads: Int,
                              alreadyNudged: Bool) -> StallAction {
        if frozen >= reloadThreshold(buffering: buffering,
                                     consecutiveReloads: consecutiveReloads) {
            return .reload
        }
        // Don't nudge a buffering player either — it's already working, and
        // play() on a starved element just churns.
        if !buffering, frozen >= nudgeAfter, !alreadyNudged { return .nudge }
        return .none
    }

    /// How long the position may stay frozen before a reload is worth it.
    public static func reloadThreshold(buffering: Bool,
                                       consecutiveReloads: Int) -> TimeInterval {
        if buffering { return bufferingReloadAfter }
        let backoff = baseReloadAfter * pow(2, Double(max(0, consecutiveReloads)))
        return min(backoff, maxReloadAfter)
    }
}
