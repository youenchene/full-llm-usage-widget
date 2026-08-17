import SwiftUI

/// The dedicated Accounts panel: one `ConnectionRow` per enabled provider, for signing in and
/// out. Usage rendering lives in the main popover.
struct ConnectionsView: View {
    let store: UsageStore
    let providers: [any UsageProvider]
    let settings: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect or disconnect providers. Live usage appears in the menu-bar panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(providers, id: \.provider) { ConnectionRow(provider: $0, store: store) }
            }
            .padding(16)
            .frame(width: 348, alignment: .leading)
        }
        .environment(\.thresholds, settings.thresholds)
    }
}
