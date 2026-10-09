import SwiftUI

/// One card for all of a Provider's Plans: the provider name as the heading, one section per Plan
/// (titled without the redundant provider prefix), then a single freshness line and error.
/// Used where a provider's Plans read as one account (Mistral: API, API Extra, Vibe).
struct ProviderCard: View {
    let provider: Provider
    let plans: [Plan]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.headline)
                if let error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }
                Spacer()
            }

            ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.sectionTitle(plan, provider: provider))
                        .font(.subheadline.weight(.semibold))
                    PlanContent(plan: plan)
                }
            }

            // The oldest fetch, so a stale section isn't masked by a fresh one.
            if let fetchedAt = plans.compactMap(\.fetchedAt).min() {
                Text(Freshness.label(fetchedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    /// "Mistral API Extra" → "API Extra"; a plan named exactly like the provider keeps its name.
    nonisolated static func sectionTitle(_ plan: Plan, provider: Provider) -> String {
        let prefix = provider.displayName + " "
        guard plan.name.hasPrefix(prefix) else { return plan.name }
        return String(plan.name.dropFirst(prefix.count))
    }
}
