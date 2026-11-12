import Foundation

/// Reads Mistral's included monthly usage from the billing API with a regular API key, the same
/// calls the official Vibe CLI makes (see docs/mistral-billing-api.md):
///
///   - `GET /v1/billing/budget`: `api_budget` and `vibe_budget`, each `{usage_percentage,
///     initial_budget, currency, reset_at, payg_enabled?}`. Needs the `see_org_inference_usage`
///     permission (403 otherwise).
///   - `GET /v1/billing/subscription`: `{plan_name, payg_enabled, vibe_payg_enabled, enterprise}`.
///     Optional; it only refines the "Pay-as-you-go" / "Hard limit" note.
///
/// Produces the same Plans as the console scrape (`mistral.api`, `mistral.vibe`, and
/// `mistral.api.extra` when the budget reports usage past 100%). The priced overage still needs the
/// console cookie (`MistralUsageCost`).
struct MistralBillingFetcher: Sendable {
    static let budgetURL = URL(string: "https://api.mistral.ai/v1/billing/budget")!
    static let subscriptionURL = URL(string: "https://api.mistral.ai/v1/billing/subscription")!

    struct Subscription: Decodable, Sendable, Equatable {
        let planName: String?
        let paygEnabled: Bool?
        let vibePaygEnabled: Bool?
        enum CodingKeys: String, CodingKey {
            case planName = "plan_name"
            case paygEnabled = "payg_enabled"
            case vibePaygEnabled = "vibe_payg_enabled"
        }
    }

    private struct Budget: Decodable {
        let apiBudget: MistralConsoleFetcher.BudgetBlock?
        let vibeBudget: MistralConsoleFetcher.BudgetBlock?
        enum CodingKeys: String, CodingKey {
            case apiBudget = "api_budget"
            case vibeBudget = "vibe_budget"
        }
    }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        async let budget = get(Self.budgetURL, apiKey: apiKey)
        async let subscription = try? get(Self.subscriptionURL, apiKey: apiKey)
        let budgetData = try await budget
        let subscriptionData = await subscription
        return try Self.parse(budget: budgetData, subscription: subscriptionData)
    }

    private func get(_ url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await UsageHTTP.session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.decoding("Non-HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ProviderError.badCredentials("Mistral rejected the API key (deleted or expired?). Sign in again.")
        case 403: throw ProviderError.badCredentials("This Mistral key can't read usage: your account needs permission to see organization usage.")
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        default:
            throw ProviderError.transport("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
        }
    }

    /// Pure JSON → `ProviderUsage` (no network), exposed for self-checks.
    static func parse(budget: Data, subscription: Data?) throws -> ProviderUsage {
        let decoded: Budget
        do {
            decoded = try JSONDecoder().decode(Budget.self, from: budget)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
        let sub = subscription.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }

        var plans: [Plan] = []
        if var api = decoded.apiBudget, api.initialBudget > 0 {
            // The org's pay-as-you-go switch lives on the subscription; the budget block's own
            // flag has been seen `false` on an org with pay-as-you-go on.
            if let payg = sub?.paygEnabled {
                api = api.with(paygEnabled: payg)
            }
            let extra = MistralConsoleFetcher.overage(of: api, apiCost: nil)
            plans.append(MistralConsoleFetcher.makeAPIPlan(from: api, hasOverage: extra != nil))
            if let extra {
                plans.append(MistralConsoleFetcher.makeAPIExtraPlan(overage: extra, currency: api.currency))
            }
        }
        if let vibe = decoded.vibeBudget, vibe.initialBudget > 0 {
            plans.append(MistralConsoleFetcher.makeVibePlan(from: vibe))
        }
        guard !plans.isEmpty else {
            throw ProviderError.decoding("No included usage in the Mistral billing response")
        }
        return ProviderUsage(provider: .mistral, plans: plans, fetchedAt: Date())
    }
}

extension MistralConsoleFetcher.BudgetBlock {
    func with(paygEnabled: Bool) -> Self {
        Self(usagePercentage: usagePercentage, initialBudget: initialBudget, currency: currency,
             resetAt: resetAt, paygEnabled: paygEnabled)
    }
}
