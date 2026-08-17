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

    /// The wired providers in the user's persisted order, filtered to enabled ones only.
    private var orderedVisibleProviders: [Provider] {
        let wired = Set(providers.map(\.provider))
        return settings.providerOrder.filter { wired.contains($0) && settings.isEnabled($0) }
    }

    var body: some View {
        let ordered = orderedVisibleProviders
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
                    ForEach(ordered, id: \.self) { provider in
                        if let plans = plansByProvider[provider], !plans.isEmpty {
                            let index = ordered.firstIndex(of: provider) ?? 0
                            ProviderBlock(
                                provider: provider,
                                plans: plans,
                                error: store.errors[provider],
                                canMoveUp: index > 0,
                                canMoveDown: index < ordered.count - 1,
                                onMoveUp: { move(provider, up: true) },
                                onMoveDown: { move(provider, up: false) }
                            )
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: DesignTokens.popoverWidth - 32, alignment: .leading)
        }
        .environment(\.thresholds, settings.thresholds)
    }

    /// Move a visible provider up or down among its visible peers, then persist the new order.
    private func move(_ provider: Provider, up: Bool) {
        var order = orderedVisibleProviders
        guard let index = order.firstIndex(of: provider) else { return }
        let target = up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        settings.reorderProviders(order)
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

/// One provider's plan cards plus up/down reorder controls, so the user can reorder providers on
/// the main tab. Multi-plan providers (e.g. OpenCode Go + Zen) stay grouped as one block.
private struct ProviderBlock: View {
    let provider: Provider
    let plans: [Plan]
    let error: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: DesignTokens.cardSpacing) {
                ForEach(plans) { PlanCard(plan: $0, error: error) }
            }
            VStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up")
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down")
            }
            .foregroundStyle(.secondary)
        }
    }
}
