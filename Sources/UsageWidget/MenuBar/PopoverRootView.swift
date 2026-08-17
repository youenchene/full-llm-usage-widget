import SwiftUI

/// The popover root: a header with refresh/settings/quit actions, an optional error banner, and
/// one row per *enabled* provider.
struct PopoverRootView: View {
    let store: UsageStore
    let providers: [any UsageProvider]
    let settings: SettingsModel
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        let visibleProviders = providers.filter { settings.isEnabled($0.provider) }
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.cardSpacing) {
                header
                if let globalError = store.globalError {
                    Text(globalError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Divider()
                ForEach(visibleProviders, id: \.provider) { ProviderRow(provider: $0, store: store) }
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
}
