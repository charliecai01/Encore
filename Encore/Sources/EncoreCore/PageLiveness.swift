import Foundation

/// Decides when the hidden web page needs rebuilding.
///
/// Three failure modes:
///
/// 1. The page went silent — no bridge messages for a while — so it MAY be
///    dead. (iOS jettisons WKWebView content processes; a hidden web view is
///    a prime target.)
/// 2. **A reload was issued and the page never came back ready.** The original
///    check only handled case 1 and was itself gated on `playerReady`, so a
///    reload that failed to load left `playerReady` false forever — disabling
///    the very watchdog meant to recover it. Observed live: a reload at
///    06:19 was followed by no `ready` for two hours, and playback limped on
///    the slow mismatch-recovery path until the app was restarted by hand.
///    Nothing retried, because the retry was gated on the state the failure
///    had cleared.
/// 3. **Silence is not death (2026-10-02).** Case 1 used to reload on silence
///    alone. But a perfectly healthy page goes silent whenever its JS timers
///    stop running: the Mac sleeping or dark-waking (the native timer fires
///    the instant it wakes, before the page's 250ms interval has run once),
///    or WebKit throttling a hidden page that isn't playing audio. Logged
///    live: 40+ "page is dead" reloads overnight on one PAUSED session, every
///    one with the same content process alive throughout (no TERMINATED
///    event), several landing to the second on a `DarkWake`. Each of those
///    reloads re-engaged the track and briefly started its audio — the
///    "random sound" report. So silence now only triggers a PROBE (one
///    `evaluateJavaScript` round trip, which runs regardless of timer
///    throttling); only a probe that fails or never answers reloads.
public enum PageLiveness {

    public enum Action: Equatable {
        case none
        /// Page is silent — ask it directly whether it's alive.
        case probeSilentPage
        /// Page is silent AND didn't answer the probe — rebuild it.
        case reloadDeadPage
        /// A previous reload never produced `ready` — try again.
        case retryFailedReload
    }

    /// Silence from a ready page that warrants a probe.
    public static let deadAfter: TimeInterval = 15
    /// How long a probe may go unanswered before the page counts as dead.
    /// A live content process answers in milliseconds even when throttled.
    public static let probeTimeout: TimeInterval = 10
    /// How long to give a reload to produce `ready` before trying again.
    /// Generous: a cold page load on a bad link legitimately takes seconds.
    public static let reloadReadyTimeout: TimeInterval = 20

    /// - Parameters:
    ///   - playerReady: has the page reported `ready` since the last reload?
    ///   - sinceLastBridge: seconds since any bridge message arrived.
    ///   - sinceLastReload: seconds since `reloadSite()` was last issued.
    ///   - probeInFlightFor: seconds since an unanswered probe was sent, or
    ///     nil when none is outstanding.
    public static func action(playerReady: Bool,
                              sinceLastBridge: TimeInterval,
                              sinceLastReload: TimeInterval,
                              probeInFlightFor: TimeInterval? = nil) -> Action {
        guard playerReady else {
            // Not ready: either a reload is still in flight (fine) or it failed
            // and nothing else will ever retry it.
            return sinceLastReload > reloadReadyTimeout ? .retryFailedReload : .none
        }
        guard sinceLastBridge > deadAfter else { return .none }
        guard let probeAge = probeInFlightFor else { return .probeSilentPage }
        return probeAge > probeTimeout ? .reloadDeadPage : .none
    }

    /// The probe sent on `.probeSilentPage`. Evaluates to 1 only when the
    /// content process is alive AND our controller is still installed —
    /// anything else (error, 0, nil) means the page needs rebuilding.
    public static let probeScript = "window.__encore ? 1 : 0"
}
