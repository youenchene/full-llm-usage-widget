import Foundation

/// The severity bucket a Progress value falls into, driving the color it renders as.
enum UrgencyLevel: String, Codable, Hashable, Sendable {
    case normal
    case warning
    case critical
}

/// The two progress thresholds that map a Progress into a color: values at or above `warning`
/// render orange, at or above `critical` render red, below both render green.
struct Thresholds: Codable, Equatable, Hashable, Sendable {
    /// Progress value at which a plan turns orange (default 0.7).
    var warning: Double = 0.7
    /// Progress value at which a plan turns red (default 0.9).
    var critical: Double = 0.9

    func level(for progress: Double) -> UrgencyLevel {
        if progress >= critical { return .critical }
        if progress >= warning { return .warning }
        return .normal
    }
}

/// How the menu-bar label picks its single plan.
enum MenuBarFocus: Hashable, Sendable {
    /// Show the most-urgent Plan (closest to its limit/budget).
    case auto
    /// Show a specific Plan by id.
    case pinned(planID: String)
}

extension MenuBarFocus: Codable {
    private enum CodingKeys: String, CodingKey { case mode, planID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "auto"
        switch mode {
        case "pinned":
            self = .pinned(planID: try container.decode(String.self, forKey: .planID))
        default:
            self = .auto
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .mode)
        case .pinned(let planID):
            try container.encode("pinned", forKey: .mode)
            try container.encode(planID, forKey: .planID)
        }
    }
}

/// The currency the menu-bar €/＄ total is displayed in.
enum DisplayCurrency: String, Codable, CaseIterable, Hashable, Sendable {
    case usd = "USD"
    case eur = "EUR"
}

/// The persisted user settings. Every field has a default so an absent value decodes cleanly.
struct SettingsState: Codable, Equatable, Sendable {
    /// Per-plan monthly Budgets, keyed by spend plan id. An unset budget means "no urgency".
    var budgets: [String: Budget]
    /// Menu-bar focus: auto (most-urgent) or pinned to a specific plan.
    var menuBarFocus: MenuBarFocus
    /// Color thresholds for progress bars.
    var thresholds: Thresholds
    /// Global poll cadence, in seconds.
    var pollIntervalSeconds: Double
    /// Display order of providers on the main tab. Providers not listed here (e.g. newly added)
    /// are appended in canonical order at render time.
    var providerOrder: [Provider]
    /// Currency the menu-bar total is shown in (USD or EUR).
    var displayCurrency: DisplayCurrency

    init(
        budgets: [String: Budget],
        menuBarFocus: MenuBarFocus,
        thresholds: Thresholds,
        pollIntervalSeconds: Double,
        providerOrder: [Provider],
        displayCurrency: DisplayCurrency
    ) {
        self.budgets = budgets
        self.menuBarFocus = menuBarFocus
        self.thresholds = thresholds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.providerOrder = providerOrder
        self.displayCurrency = displayCurrency
    }

    static let `default` = SettingsState(
        budgets: [:],
        menuBarFocus: .auto,
        thresholds: Thresholds(),
        pollIntervalSeconds: 60,
        providerOrder: Provider.allCases,
        displayCurrency: .eur
    )

    private enum CodingKeys: String, CodingKey {
        case budgets, menuBarFocus, thresholds, pollIntervalSeconds, providerOrder, displayCurrency
    }

    /// Decode with a graceful fallback for `providerOrder` and `displayCurrency`, so a
    /// `settings.json` written before those existed still loads instead of resetting every setting.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.budgets = try container.decode([String: Budget].self, forKey: .budgets)
        self.menuBarFocus = try container.decode(MenuBarFocus.self, forKey: .menuBarFocus)
        self.thresholds = try container.decode(Thresholds.self, forKey: .thresholds)
        self.pollIntervalSeconds = try container.decode(Double.self, forKey: .pollIntervalSeconds)
        self.providerOrder = try container.decodeIfPresent([Provider].self, forKey: .providerOrder)
            ?? Provider.allCases
        self.displayCurrency = try container.decodeIfPresent(DisplayCurrency.self, forKey: .displayCurrency)
            ?? .eur
    }
}
