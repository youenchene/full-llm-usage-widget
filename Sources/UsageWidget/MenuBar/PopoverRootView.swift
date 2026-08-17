import SwiftUI

/// The popover root: a header, an optional error banner, and one row per provider.
struct PopoverRootView: View {
    let store: UsageStore
    let providers: [any UsageProvider]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.cardSpacing) {
                header
                if let globalError = store.globalError {
                    Text(globalError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Divider()
                ForEach(providers, id: \.provider) { ProviderRow(provider: $0, store: store) }
            }
            .padding(16)
            .frame(width: DesignTokens.popoverWidth - 32, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("LLM Usage")
                .font(.headline)
            if let lastUpdatedAt = store.lastUpdatedAt {
                Text("Updated \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
