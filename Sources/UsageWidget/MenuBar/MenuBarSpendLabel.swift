import SwiftUI

/// The two-line menu-bar label: total € spent (line 1) and the average quota-plan percentage
/// (line 2). Each line renders independently — line 2 ("plan N%") shows even when there's no €
/// spend data, so quota-only setups don't fall back to the single most-urgent %.
///
/// Rendering is hosted in an `NSHostingView` set as the status item's view; clicks are handled by
/// an `NSClickGestureRecognizer` in `StatusBarController`.
struct MenuBarSpendLabel: View {
    let store: UsageStore

    private var amountFont: Font {
        .system(size: 9, weight: .regular, design: .monospaced).monospacedDigit()
    }
    private var planFont: Font {
        .system(size: 8, weight: .regular, design: .monospaced).monospacedDigit()
    }
    private var fallbackFont: Font { .system(.body, design: .monospaced) }

    var body: some View {
        Group {
            if store.totalSpend != nil || store.averageQuotaProgress != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let total = store.totalSpend {
                        Text("api \(Formatting.compactCurrency(total, code: store.displayCurrency.rawValue))")
                            .font(amountFont)
                    }
                    if let average = store.averageQuotaProgress {
                        Text("plan \(Formatting.percent(average.value))")
                            .font(planFont)
                    }
                }
            } else if let progress = store.menuBarProgress {
                Text(Formatting.percent(progress.value))
                    .font(fallbackFont)
            } else {
                Text("LLM")
                    .font(fallbackFont)
            }
        }
        .padding(.horizontal, 2)
        .fixedSize()
    }
}
