import SwiftUI
import AppKit

/// Routes horizontal two-finger trackpad swipes to the row currently under
/// the cursor (rows register on hover). Vertical scrolling passes through
/// untouched; a clearly-horizontal gesture is captured for swipe actions.
@MainActor
final class SwipeRouter {
    static let shared = SwipeRouter()

    struct Target {
        let id: String
        let canSwipeLeft: Bool
        let canSwipeRight: Bool
        let onChange: (CGFloat) -> Void
        let onEnd: (CGFloat) -> Void
    }

    var target: Target?

    private var accumulated: CGFloat = 0
    private var active = false
    private var installed = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func unregister(id: String) {
        if target?.id == id {
            if active {
                target?.onChange(0)
                active = false
                accumulated = 0
            }
            target = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let target else { return event }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if !active {
            guard event.momentumPhase == [],
                  target.canSwipeLeft || target.canSwipeRight,
                  abs(dx) > abs(dy) * 1.5, abs(dx) > 3 else { return event }
            active = true
            accumulated = 0
        }

        if event.phase == .ended || event.phase == .cancelled {
            let final = accumulated
            active = false
            accumulated = 0
            target.onEnd(final)
            return nil
        }
        if event.momentumPhase != [] {
            return nil
        }

        accumulated += dx
        var shown = accumulated
        if !target.canSwipeRight && shown > 0 { shown = 0 }
        if !target.canSwipeLeft && shown < 0 { shown = 0 }
        target.onChange(shown)
        return nil
    }
}
