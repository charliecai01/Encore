import Foundation

/// Decides when the hidden web page needs rebuilding.
///
/// Two failure modes, and the second one is the reason this exists:
///
/// 1. The page went silent — no bridge messages for a while — so it's dead and
///    needs a reload. (iOS jettisons WKWebView content processes; a hidden
///    web view is a prime target.)
/// 2. **A reload was issued and the page never came back ready.** The original
///    check only handled case 1 and was itself gated on `playerReady`, so a
///    reload that failed to load left `playerReady` false forever — disabling
///    the very watchdog meant to recover it. Observed live: a reload at
///    06:19 was followed by no `ready` for two hours, and playback limped on
///    the slow mismatch-recovery path until the app was restarted by hand.
///    Nothing retried, because the retry was gated on the state the failure
///    had cleared.
public enum PageLiveness {

    public enum Action: Equatable {
        case none
        /// Page is silent — rebuild it.
        case reloadDeadPage
        /// A previous reload never produced `ready` — try again.
        case retryFailedReload
    }

    /// Silence from a ready page that means it died.
    public static let deadAfter: TimeInterval = 15
    /// How long to give a reload to produce `ready` before trying again.
    /// Generous: a cold page load on a bad link legitimately takes seconds.
    public static let reloadReadyTimeout: TimeInterval = 20

    /// - Parameters:
    ///   - playerReady: has the page reported `ready` since the last reload?
    ///   - sinceLastBridge: seconds since any bridge message arrived.
    ///   - sinceLastReload: seconds since `reloadSite()` was last issued.
    public static func action(playerReady: Bool,
                              sinceLastBridge: TimeInterval,
                              sinceLastReload: TimeInterval) -> Action {
        guard playerReady else {
            // Not ready: either a reload is still in flight (fine) or it failed
            // and nothing else will ever retry it.
            return sinceLastReload > reloadReadyTimeout ? .retryFailedReload : .none
        }
        return sinceLastBridge > deadAfter ? .reloadDeadPage : .none
    }
}
