import Foundation

/// One budget as `GET /console/api/policies/current-budgets` describes it (the subset we use).
struct ConsoleBudget: Decodable, Sendable, Equatable {
    struct Model: Decodable, Sendable, Equatable {
        let name: String
    }
    let ruleID: String
    let limitDollars: Decimal
    let spentDollars: Decimal
    /// `each`: limits every member separately. `combined`: pools spend against one limit.
    let scope: String?
    /// `set`: counts spend across the budget's models. `model`: limits each model separately.
    let per: String?
    /// `all`: covers every model and billable service. `models`: covers only `models`.
    let coverage: String?
    let models: [Model]?
    let shared: Bool?
    let resetsAt: String?

    /// Share of the limit already spent. A `$0` budget blocks everything, so it counts as full.
    var ratio: Double {
        guard limitDollars > 0 else { return 1 }
        return NSDecimalNumber(decimal: spentDollars).doubleValue / NSDecimalNumber(decimal: limitDollars).doubleValue
    }

    var coversAllSpend: Bool { (coverage ?? "all") == "all" && (per ?? "set") == "set" }
}

/// Reads the member's monthly spend and Budgets from the OpenCode Console (formerly Zen), using a
/// bearer credential (device-login token or personal API key) plus the workspace ID.
///
/// The Console has no documented balance endpoint, so this yields `spent` + `budget` only. The
/// optional cookie scrape (`OpenCodeConsoleBalanceFetcher`) adds the `Balance`.
struct OpenCodeBudgetsFetcher: Sendable {
    static let url = URL(string: "\(OpenCodeConsole.server)/api/policies/current-budgets")!

    /// The member's budgets, or `nil` when the Console refuses them (403: a service-account key,
    /// or a key without Budgets › Read).
    func fetch(credential: OpenCodeCredential) async throws -> [ConsoleBudget]? {
        let request = OpenCodeConsole.request(Self.url, credential: credential, workspaceHeader: "x-org-id")
        guard let data = try await OpenCodeConsole.getOptional(request) else { return nil }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [ConsoleBudget] {
        do {
            return try JSONDecoder().decode([ConsoleBudget].self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    /// The budget to show: the closest to its limit among those covering all spend, else among all.
    static func headline(_ budgets: [ConsoleBudget]) -> ConsoleBudget? {
        let allSpend = budgets.filter(\.coversAllSpend)
        return (allSpend.isEmpty ? budgets : allSpend).max { $0.ratio < $1.ratio }
    }

    /// Build the Console spend Plan. With no budget there is no spend figure to read, so the Plan
    /// carries a note telling the user how to get one.
    static func makePlan(budgets: [ConsoleBudget], balance: Decimal?) -> Plan {
        var plan = Plan(
            id: OpenCodeConsoleBalanceFetcher.planID,
            provider: .openCode,
            name: OpenCodeConsoleBalanceFetcher.planName,
            kind: .spend,
            balance: balance.map { Balance(amount: $0, currencyCode: "USD") },
            currencyCode: "USD"
        )
        guard let budget = headline(budgets) else {
            plan.note = "No budget policy: add one in Console › Controls to track monthly spend."
            return plan
        }
        plan.spent = budget.spentDollars
        plan.budget = Budget(amount: budget.limitDollars, currencyCode: "USD")
        plan.note = note(for: budget, others: budgets.count - 1)
        return plan
    }

    private static func note(for budget: ConsoleBudget, others: Int) -> String {
        var parts: [String] = []
        if budget.scope == "combined" || budget.shared == true {
            parts.append("Shared workspace budget")
        } else {
            parts.append("Your monthly budget")
        }
        if budget.coverage == "models", let models = budget.models, !models.isEmpty {
            let names = models.prefix(2).map(\.name).joined(separator: ", ")
            parts.append(models.count > 2 ? "\(names) +\(models.count - 2)" : names)
        }
        if others > 0 {
            parts.append("+\(others) more")
        }
        return parts.joined(separator: " · ")
    }
}
