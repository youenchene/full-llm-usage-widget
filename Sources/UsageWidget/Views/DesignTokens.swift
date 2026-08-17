import SwiftUI

/// Shared design tokens for plan cards, progress bars, and states.
enum DesignTokens {
    static let cornerRadius: CGFloat = 10
    static let cardSpacing: CGFloat = 12
    static let popoverWidth: CGFloat = 312

    /// Urgency color for a normalized 0–1 progress value.
    static func progressColor(_ progress: Double) -> Color {
        switch progress {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
