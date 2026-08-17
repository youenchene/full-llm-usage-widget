import Foundation

/// Fetches Mistral organization usage from the admin API.
///
/// `GET /v1/admin/usage` returns a large per-model usage report with a top-level `currency` and
/// per-block `cost` fields. There is no single "total cost" field, so we sum every `cost` leaf
/// across the whole response. Auth is an admin-scoped API key (Bearer).
struct MistralUsageFetcher: Sendable {
    static let usageURL = URL(string: "https://api.mistral.ai/v1/admin/usage")!

    func fetch(apiKey: String) async throws -> ProviderUsage {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        // The Admin API authenticates via the `x-api-key` header (NOT `Authorization: Bearer`,
        // which is the regular inference-API style).
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await UsageHTTP.get(
            request,
            onUnauthorized: "Mistral rejected the key — use an Admin API key (admin.mistral.ai → API Keys), not a standard API key."
        )
        return try Self.parse(data)
    }

    /// Pure JSON → `ProviderUsage` mapping (no network), exposed for self-checks.
    static func parse(_ data: Data) throws -> ProviderUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Non-JSON Mistral response")
        }
        // Defensive unwrap in case the API wraps the payload under a "usage" key.
        let body = (json["usage"] as? [String: Any]) ?? json
        let currency = (body["currency"] as? String)?.uppercased() ?? "USD"
        let total = sumCost(body)
        let spent = Decimal(string: String(total)) ?? Decimal(total)

        let plan = Plan(
            id: Provider.mistral.rawValue,
            provider: .mistral,
            name: "Mistral",
            kind: .spend,
            spent: spent,
            currencyCode: currency
        )
        return ProviderUsage(provider: .mistral, plans: [plan], fetchedAt: Date())
    }

    /// Recursively sum every numeric `cost` field in the response. Each cost appears once as a
    /// leaf, so this never double-counts regardless of how deeply the model usage data is nested.
    static func sumCost(_ value: Any) -> Double {
        switch value {
        case let dict as [String: Any]:
            var total = 0.0
            for (key, child) in dict {
                if key == "cost", let n = asNumber(child) {
                    total += n
                } else {
                    total += sumCost(child)
                }
            }
            return total
        case let arr as [Any]:
            return arr.reduce(0) { $0 + sumCost($1) }
        default:
            return 0
        }
    }

    private static func asNumber(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
