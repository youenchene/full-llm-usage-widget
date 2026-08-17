import SwiftUI

/// A spend plan the user can set a monthly Budget for. Plan ids are stable (see the fetchers),
/// so budgets are keyed by id and survive sign-out/sign-in.
struct SpendPlanInfo: Identifiable {
    let id: String
    let name: String
    let currency: String
}

/// The settings window: provider toggles, spend-plan budgets, menu-bar focus, threshold colors,
/// poll interval, and launch-at-login.
struct SettingsView: View {
    let settings: SettingsModel
    let store: UsageStore

    private let launchAtLogin = LaunchAtLogin()
    @State private var launchAtLoginError: String?

    /// The spend plans the widget can track, with their default budget currency.
    private static let spendPlans: [SpendPlanInfo] = [
        SpendPlanInfo(id: "mistral", name: "Mistral", currency: "EUR"),
        SpendPlanInfo(id: "scaleway", name: "Scaleway", currency: "EUR"),
        SpendPlanInfo(id: "claude.api", name: "Claude API", currency: "USD"),
        SpendPlanInfo(id: "opencode.zen", name: "OpenCode Zen", currency: "USD")
    ]

    var body: some View {
        Form {
            providersSection
            budgetsSection
            menuBarSection
            thresholdsSection
            pollingSection
            launchAtLoginSection
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Providers

    private var providersSection: some View {
        Section("Providers") {
            ForEach(Provider.allCases) { provider in
                Toggle(provider.displayName, isOn: providerBinding(provider))
                    .toggleStyle(.switch)
                    .tint(.blue)
            }
        }
    }

    private func providerBinding(_ provider: Provider) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(provider) },
            set: { settings.setEnabled($0, for: provider) }
        )
    }

    // MARK: - Budgets

    private var budgetsSection: some View {
        Section {
            ForEach(Self.spendPlans) { info in
                BudgetRow(info: info, settings: settings)
            }
        } header: {
            Text("Monthly budgets (spend plans)")
        } footer: {
            Text("A spend plan with no budget shows only its currency figure — no urgency.")
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        Section("Menu bar") {
            Picker("Show", selection: focusBinding) {
                Text("Most urgent plan").tag(MenuBarFocus.auto)
                ForEach(store.visiblePlans) { plan in
                    Text(plan.name).tag(MenuBarFocus.pinned(planID: plan.id))
                }
            }
        }
    }

    private var focusBinding: Binding<MenuBarFocus> {
        Binding(
            get: { settings.menuBarFocus },
            set: { settings.setMenuBarFocus($0) }
        )
    }

    // MARK: - Thresholds

    private var thresholdsSection: some View {
        Section {
            HStack {
                Text("Warning (orange)")
                Spacer()
                Slider(value: warningBinding, in: 0.05...0.95)
                    .frame(width: 160)
                Text("\(Int((settings.thresholds.warning * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("Critical (red)")
                Spacer()
                Slider(value: criticalBinding, in: 0.05...0.95)
                    .frame(width: 160)
                Text("\(Int((settings.thresholds.critical * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        } header: {
            Text("Threshold colors")
        }
    }

    private var warningBinding: Binding<Double> {
        Binding(
            get: { settings.thresholds.warning },
            set: { settings.setThresholds(Thresholds(warning: $0, critical: settings.thresholds.critical)) }
        )
    }

    private var criticalBinding: Binding<Double> {
        Binding(
            get: { settings.thresholds.critical },
            set: { settings.setThresholds(Thresholds(warning: settings.thresholds.warning, critical: $0)) }
        )
    }

    // MARK: - Polling

    private var pollingSection: some View {
        Section {
            HStack {
                Text("Poll interval")
                Spacer()
                Slider(value: pollIntervalBinding, in: 30...900, step: 30)
                    .frame(width: 160)
                Text(Self.intervalLabel(settings.pollInterval))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        } footer: {
            Text("How often the widget checks every enabled provider. Individual providers may poll slower to respect rate limits.")
        }
    }

    private var pollIntervalBinding: Binding<Double> {
        Binding(
            get: { Double(settings.pollInterval.components.seconds) },
            set: { settings.setPollIntervalSeconds($0) }
        )
    }

    private static func intervalLabel(_ interval: Duration) -> String {
        let seconds = interval.components.seconds
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }

    // MARK: - Launch at login

    private var launchAtLoginSection: some View {
        Section {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
                .toggleStyle(.switch)
                .tint(.blue)
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Registered via SMAppService. A development build outside /Applications may not be registrable.")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { enabled in
                do {
                    try launchAtLogin.setEnabled(enabled)
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
            }
        )
    }
}

/// A single budget editor: a currency field that commits to the settings model as you type.
private struct BudgetRow: View {
    let info: SpendPlanInfo
    let settings: SettingsModel

    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(info.name)
                .frame(width: 120, alignment: .leading)
            TextField("No budget", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .onChange(of: text) { commit() }
            Text(info.currency)
                .foregroundStyle(.secondary)
                .font(.caption)
            if !text.isEmpty {
                Button {
                    text = ""
                    commit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { text = Self.string(from: settings.budget(for: info.id)) }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            settings.setBudget(nil, currencyCode: info.currency, for: info.id)
            return
        }
        guard let amount = Self.parse(trimmed) else { return }
        settings.setBudget(amount, currencyCode: info.currency, for: info.id)
    }

    private static func string(from budget: Budget?) -> String {
        guard let budget else { return "" }
        return NSDecimalNumber(decimal: budget.amount).stringValue
    }

    private static func parse(_ text: String) -> Decimal? {
        let posix = Locale(identifier: "en_US_POSIX")
        if let value = Decimal(string: text, locale: posix) { return value }
        return Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: posix)
    }
}
