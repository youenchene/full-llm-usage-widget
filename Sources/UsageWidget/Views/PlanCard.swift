import SwiftUI

/// A single Plan's card: quota plans render % bars + reset countdowns; spend plans render raw
/// currency (or a % toward a Budget when one is set).
struct PlanCard: View {
    let plan: Plan
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(plan.name)
                    .font(.headline)
                if let error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }
                Spacer()
            }

            switch plan.kind {
            case .quota:
                ForEach(plan.limitWindows) { LimitWindowBar(window: $0) }
            case .spend:
                SpendSummary(plan: plan)
            }

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}

/// Raw currency for a spend plan, plus a % bar only when a Budget is set (ADR-0002).
private struct SpendSummary: View {
    let plan: Plan

    var body: some View {
        let code = plan.currencyCode ?? "USD"
        VStack(alignment: .leading, spacing: 6) {
            if let spent = plan.spent {
                Text(Formatting.currency(spent, code: code))
                    .font(.title3.monospacedDigit())
            } else {
                Text("No spend data")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let budget = plan.budget, budget.amount > 0, let progress = plan.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(DesignTokens.progressColor(progress.value))
                            .frame(width: max(geo.size.width * progress.value, 4))
                    }
                }
                .frame(height: 6)
                Text("\(Formatting.percent(progress.value)) of \(Formatting.currency(budget.amount, code: code)) budget")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
