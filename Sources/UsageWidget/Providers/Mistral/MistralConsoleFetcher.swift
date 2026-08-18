import Foundation

/// Fetches Mistral's included monthly usage (a quota window) from the admin console's
/// `/subscription` page.
///
/// The Mistral Admin API (`/v1/admin/usage`) is Enterprise-only. For Pro/Free accounts the only
/// programmatic signal is the "included monthly usage" budget, which is embedded server-side in
/// the `admin.mistral.ai/subscription` RSC payload (no separate JSON endpoint exists). Auth is an
/// Ory session cookie (`ory_session_…`), sent as a plain `Cookie` header — see
/// docs/mistral-console-scrape.md.
struct MistralConsoleFetcher: Sendable {
    static let subscriptionURL = URL(string: "https://admin.mistral.ai/subscription")!

    func fetch(sessionCookie: String) async throws -> ProviderUsage {
        var request = URLRequest(url: Self.subscriptionURL)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let data = try await UsageHTTP.get(
            request,
            onUnauthorized: "Mistral console session rejected — re-paste the session cookie."
        )
        return try Self.parse(data)
    }

    /// Pure HTML → `ProviderUsage` mapping (no network), exposed for self-checks.
    static func parse(_ data: Data) throws -> ProviderUsage {
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.decoding("Non-UTF8 Mistral response")
        }
        // An expired session serves the login page instead of the subscription data — treat the
        // absence of the budget block as a re-auth signal.
        guard let block = extractBudgetBlock(named: "api_budget", from: html) else {
            throw ProviderError.unauthorized
        }
        guard block.initialBudget > 0 else {
            throw ProviderError.decoding("Zero Mistral API budget")
        }

        let usedPercent = block.usagePercentage
        let usedAmount = Decimal(block.initialBudget * usedPercent / 100)
        let limitAmount = Decimal(block.initialBudget)
        let note = "\(Formatting.currency(usedAmount, code: block.currency)) of \(Formatting.currency(limitAmount, code: block.currency)) included monthly"

        let plan = Plan(
            id: "\(Provider.mistral.rawValue).api",
            provider: .mistral,
            name: "Mistral API",
            kind: .quota,
            limitWindows: [
                LimitWindow(
                    label: "monthly",
                    used: usedPercent,
                    limit: 100,
                    resetsAt: Self.parseDate(block.resetAt)
                )
            ],
            note: note,
            fetchedAt: Date()
        )
        return ProviderUsage(provider: .mistral, plans: [plan], fetchedAt: Date())
    }

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
