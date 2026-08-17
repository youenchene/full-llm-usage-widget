import SwiftUI

/// The main popover: usage only. Sign-in / sign-out live in the dedicated Accounts panel.
struct PopoverRootView: View {
    let store: UsageStore
    let providers: [any UsageProvider]
    let settings: SettingsModel
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAccounts: () -> Void
    let onQuit: () -> Void

    var body: some View {
        let visibleProviders = providers.filter { settings.isEnabled($0.provider) }
        let plansByProvider = Dictionary(grouping: store.visiblePlans, by: { $0.provider })

        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.cardSpacing) {
                header
                if let globalError = store.globalError {
                    Text(globalError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Divider()

                if store.visiblePlans.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleProviders, id: \.provider) { provider in
                        if let plans = plansByProvider[provider.provider], !plans.isEmpty {
                            ForEach(plans) { PlanCard(plan: $0, error: store.errors[provider.provider]) }
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: DesignTokens.popoverWidth - 32, alignment: .leading)
        }
        .environment(\.thresholds, settings.thresholds)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LLM Usage")
                    .font(.headline)
                if let lastUpdatedAt = store.lastUpdatedAt {
                    Text("Updated \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
                Button(action: onOpenAccounts) {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .help("Accounts")
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .help("Quit")
            }
            .buttonStyle(.borderless)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No usage yet")
                .font(.headline)
            Text("Connect a provider to see live usage here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Manage connections", action: onOpenAccounts)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}
