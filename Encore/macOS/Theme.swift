import SwiftUI

enum Theme {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.075)
    static let bgElevated = Color(red: 0.09, green: 0.09, blue: 0.115)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.115)
    static let stroke = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let fallbackAccent = Color(red: 1.0, green: 0.32, blue: 0.38)
}

extension View {
    /// Standard hover-highlight used across rows and cards.
    func hoverHighlight(_ hovering: Bool, corner: CGFloat = 8) -> some View {
        background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(hovering ? Theme.cardHover : Color.clear)
        )
    }
}
