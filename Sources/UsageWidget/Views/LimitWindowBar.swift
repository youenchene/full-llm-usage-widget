import SwiftUI

/// A single quota window: label, % used, a progress bar, and a reset countdown.
/// An `unlimited` window renders "Unlimited" instead of a bar.
struct LimitWindowBar: View {
    let window: LimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.caption)
                Spacer()
                Text(window.unlimited ? "Unlimited" : Formatting.percent(window.progress.value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(window.unlimited ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            if !window.unlimited {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(DesignTokens.progressColor(window.progress.value))
                            .frame(width: max(geo.size.width * window.progress.value, 4))
                    }
                }
                .frame(height: 6)
            }
            CountdownText(resetsAt: window.resetsAt)
        }
    }
}
