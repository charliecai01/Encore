import Foundation

/// Bounds the hidden music.youtube.com page's memory on macOS.
///
/// The page is a long-lived SPA in one WebKit content process, and nothing on
/// macOS ever reclaims it: observed 2026-10-02 at 1.2 GB physical footprint
/// (2.6 GB RSS, almost all "WebKit Malloc" — the site's JS heap) after an 8h
/// session, still climbing while paused. iOS jettisons the process under
/// pressure and `PageLiveness` recovers it; macOS needs to recycle on its own.
///
/// Recycling = a page reload, which is only safe when nobody can notice it:
/// paused for a while, and the video panel isn't showing the page. With the
/// document-start `AutoplayGuard` and the no-engage-while-paused `ready` path,
/// a paused reload makes no sound; the next play re-engages the track at the
/// saved position.
public enum PageMemory {
    /// Physical footprint above which an idle page gets recycled. A freshly
    /// loaded page sits well under this.
    public static let recycleAbove: UInt64 = 1_536 * 1024 * 1024
    /// How long playback must have been paused first.
    public static let idleBeforeRecycle: TimeInterval = 120
    /// Footprint is sampled at most this often.
    public static let checkEvery: TimeInterval = 60

    public static func shouldRecycle(footprint: UInt64?,
                                     isPlaying: Bool,
                                     pausedFor: TimeInterval,
                                     pageVisible: Bool) -> Bool {
        guard let footprint, footprint > recycleAbove else { return false }
        return !isPlaying && !pageVisible && pausedFor >= idleBeforeRecycle
    }
}
