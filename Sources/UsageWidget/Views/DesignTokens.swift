import SwiftUI

/// Shared design tokens for plan cards, progress bars, and states.
enum DesignTokens {
    static let cornerRadius: CGFloat = 10
    static let cardSpacing: CGFloat = 12
    static let popoverWidth: CGFloat = 312

    /// Urgency color for a normalized 0–1 progress value, under the given thresholds.
    static func progressColor(_ progress: Double, thresholds: Thresholds) -> Color {
        switch thresholds.level(for: progress) {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Injects the user's color thresholds so any progress bar picks them up without explicit
/// threading. Set once at the popover root; views read it via `@Environment(\.thresholds)`.
private struct ThresholdsKey: EnvironmentKey {
    static let defaultValue = Thresholds()
}

extension EnvironmentValues {
    var thresholds: Thresholds {
        get { self[ThresholdsKey.self] }
        set { self[ThresholdsKey.self] = newValue }
    }
}
