import Foundation

/// Fetches Mistral's included monthly usage (quota windows) from the admin console's
/// `/subscription` page.
///
/// The Mistral Admin API (`/v1/admin/usage`) is Enterprise-only. For Pro/Free accounts the only
/// programmatic signal is the "included monthly usage" budget, which is embedded server-side in
/// the `admin.mistral.ai/subscription` RSC payload (no separate JSON endpoint exists). Auth is an
/// Ory session cookie (`ory_session_…`), sent as a plain `Cookie` header — see
/// docs/mistral-console-scrape.md.
///
/// The console exposes up to three budgets:
///   1. `api_budget` — the included monthly API usage (a quota with a hard limit).
///   2. `vibe_budget` — the included monthly Vibe Code usage (a quota).
///   3. API extra usage — the pay-as-you-go overage beyond the included budget (a spend).
///      The budget caps `usage_percentage` at 100, so the overage is priced from the console's
///      usage endpoint (`MistralUsageCost`): extra = month's API cost − `initial_budget`.
struct MistralConsoleFetcher: Sendable {
    static let subscriptionURL = URL(string: "https://admin.mistral.ai/subscription")!
    private static let unauthorizedMessage = "Mistral console session rejected — re-paste the session cookie."

    func fetch(sessionCookie: String, now: Date = Date()) async throws -> ProviderUsage {
        let page = try await UsageHTTP.get(
            Self.request(Self.subscriptionURL, cookie: sessionCookie, accept: "text/html,application/xhtml+xml"),
            onUnauthorized: Self.unauthorizedMessage
        )
        // Best-effort: without the usage cost the plans still render, minus the priced overage.
        let apiCost = try? await fetchAPICost(sessionCookie: sessionCookie, now: now)
        return try Self.parse(page, apiCost: apiCost)
    }

    /// The current month's API cost, priced from `/api/billing/v2/usage` (calendar month, as the
    /// console computes it in the browser).
    private func fetchAPICost(sessionCookie: String, now: Date) async throws -> Decimal {
        let parts = Calendar.current.dateComponents([.month, .year], from: now)
        let url = MistralUsageCost.url(month: parts.month ?? 1, year: parts.year ?? 1970)
        let data = try await UsageHTTP.get(
            Self.request(url, cookie: sessionCookie, accept: "application/json"),
            onUnauthorized: Self.unauthorizedMessage
        )
        return try MistralUsageCost.apiCost(from: data).amount
    }

    private static func request(_ url: URL, cookie: String, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    /// Pure HTML → `ProviderUsage` mapping (no network), exposed for self-checks. `apiCost` is the
    /// month's priced API usage (from `MistralUsageCost`); when `nil`, the overage falls back to
    /// `usage_percentage > 100`.
    static func parse(_ data: Data, apiCost: Decimal? = nil) throws -> ProviderUsage {
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.decoding("Non-UTF8 Mistral response")
        }
        // An expired session serves the login page instead of the subscription data — treat the
        // absence of the budget block as a re-auth signal.
        guard let apiBlock = extractBudgetBlock(named: "api_budget", from: html) else {
            throw ProviderError.unauthorized
        }
        guard apiBlock.initialBudget > 0 else {
            throw ProviderError.decoding("Zero Mistral API budget")
        }

        let extra = Self.overage(of: apiBlock, apiCost: apiCost)
        var plans: [Plan] = []

        // 1. API included usage (quota)
        plans.append(makeAPIPlan(from: apiBlock, hasOverage: extra != nil))

        // 2. API extra usage (spend) — only when overage > 0
        if let extra {
            plans.append(makeAPIExtraPlan(overage: extra, currency: apiBlock.currency))
        }

        // 3. Vibe usage (quota) — optional
        if let vibeBlock = extractBudgetBlock(named: "vibe_budget", from: html),
           vibeBlock.initialBudget > 0 {
            plans.append(makeVibePlan(from: vibeBlock))
        }

        return ProviderUsage(provider: .mistral, plans: plans, fetchedAt: Date())
    }

    // MARK: - Plan builders

    /// The pay-as-you-go overage beyond the included budget, or `nil` when there is none.
    /// Prefers the priced `apiCost`; falls back to `usage_percentage > 100` (older payloads that
    /// didn't cap the percentage).
    private static func overage(of block: BudgetBlock, apiCost: Decimal?) -> Decimal? {
        let amount: Decimal
        if let apiCost {
            amount = apiCost - Decimal(block.initialBudget)
        } else {
            amount = Decimal(block.initialBudget * (block.usagePercentage - 100) / 100)
        }
        return amount > Decimal(string: "0.005")! ? amount : nil
    }

    /// The included monthly API usage as a quota plan. The `initial_budget` is the top of the
    /// progress indicator. The note says "Pay-as-you-go" when overage is allowed or observed,
    /// "Hard limit" only when the payload explicitly says `payg_enabled: false`.
    private static func makeAPIPlan(from block: BudgetBlock, hasOverage: Bool) -> Plan {
        let usedAmount = block.initialBudget * block.usagePercentage / 100
        let limitAmount = block.initialBudget
        let limitType: String? = (hasOverage || block.paygEnabled == true)
            ? "Pay-as-you-go"
            : (block.paygEnabled == false ? "Hard limit" : nil)
        let included = "\(Formatting.currency(Decimal(usedAmount), code: block.currency)) of \(Formatting.currency(Decimal(limitAmount), code: block.currency)) included monthly"
        let note = limitType.map { "\(included) • \($0)" } ?? included

        return Plan(
            id: "\(Provider.mistral.rawValue).api",
            provider: .mistral,
            name: "Mistral API",
            kind: .quota,
            limitWindows: [
                LimitWindow(
                    label: "monthly",
                    used: usedAmount,
                    limit: limitAmount,
                    resetsAt: Self.parseDate(block.resetAt)
                )
            ],
            note: note,
            fetchedAt: Date()
        )
    }

    /// The pay-as-you-go overage beyond the included budget, as a spend plan.
    private static func makeAPIExtraPlan(overage: Decimal, currency: String) -> Plan {
        Plan(
            id: "\(Provider.mistral.rawValue).api.extra",
            provider: .mistral,
            name: "Mistral API Extra",
            kind: .spend,
            spent: overage,
            currencyCode: currency,
            note: "\(Formatting.currency(overage, code: currency)) overage this month",
            fetchedAt: Date()
        )
    }

    /// The included monthly Vibe Code usage as a quota plan.
    private static func makeVibePlan(from block: BudgetBlock) -> Plan {
        let usedAmount = block.initialBudget * block.usagePercentage / 100
        let limitAmount = block.initialBudget
        let note = "\(Formatting.currency(Decimal(usedAmount), code: block.currency)) of \(Formatting.currency(Decimal(limitAmount), code: block.currency)) included monthly (Vibe)"

        return Plan(
            id: "\(Provider.mistral.rawValue).vibe",
            provider: .mistral,
            name: "Mistral Vibe",
            kind: .quota,
            limitWindows: [
                LimitWindow(
                    label: "monthly",
                    used: usedAmount,
                    limit: limitAmount,
                    resetsAt: Self.parseDate(block.resetAt)
                )
            ],
            note: note,
            fetchedAt: Date()
        )
    }

    // MARK: - Payload extraction

    /// Flat shape of the `api_budget` (and `vibe_budget`) block embedded in the RSC payload.
    private struct BudgetBlock: Decodable {
        let usagePercentage: Double
        let initialBudget: Double
        let currency: String
        let resetAt: String
        let paygEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case usagePercentage = "usage_percentage"
            case initialBudget = "initial_budget"
            case currency
            case resetAt = "reset_at"
            case paygEnabled = "payg_enabled"
        }
    }

    /// Extract the `name` budget block from the HTML. The block sits inside the RSC payload's
    /// JSON-string form, so keys/values appear backslash-escaped (`\"api_budget\":{…}`). The block
    /// is flat (scalar values only — see docs/mistral-console-scrape.md), so the first `{` after
    /// the key opens it and the first `}` closes it.
    private static func extractBudgetBlock(named name: String, from html: String) -> BudgetBlock? {
        guard let keyRange = html.range(of: name) else { return nil }
        let open: Character = "{"
        let close: Character = "}"
        guard let start = html[keyRange.upperBound...].firstIndex(of: open) else { return nil }
        guard let end = html[html.index(after: start)...].firstIndex(of: close) else { return nil }
        let raw = String(html[start...end])
        let json = raw.replacingOccurrences(of: "\\\"", with: "\"")
        return try? JSONDecoder().decode(BudgetBlock.self, from: Data(json.utf8))
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
