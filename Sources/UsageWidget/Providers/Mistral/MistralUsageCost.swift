import Foundation

/// Prices the month's API usage from the console's `GET /api/billing/v2/usage?month=&year=`
/// response (same Ory session cookie as the `/subscription` page).
///
/// The `/subscription` budget caps `usage_percentage` at 100, so it cannot show pay-as-you-go
/// overage. The usage endpoint carries raw per-model rows plus a `prices` table; the console's own
/// `calculateCost` is Σ `value_paid × unit price`, which is reproduced here. See
/// docs/mistral-console-scrape.md.
enum MistralUsageCost {
    static func url(month: Int, year: Int) -> URL {
        URL(string: "https://admin.mistral.ai/api/billing/v2/usage?month=\(month)&year=\(year)")!
    }

    /// Categories with their own allowance (Vibe Code budget, Le Chat), not billed against the
    /// API budget, plus non-usage keys.
    private static let excludedKeys: Set<String> = ["vibe_code", "vibe_usage", "chat", "prices"]

    /// Total API cost for the month, in the response's currency.
    static func apiCost(from data: Data) throws -> (amount: Decimal, currency: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPrices = root["prices"] as? [[String: Any]] else {
            throw ProviderError.decoding("Unexpected Mistral usage payload")
        }
        let prices = PriceTable(rawPrices)
        let rows = root
            .filter { !excludedKeys.contains($0.key) }
            .flatMap { collectRows($0.value) }
        let amount = rows.reduce(Decimal(0)) { total, row in
            total + row.paid * (prices.price(for: row) ?? 0)
        }
        return (amount, root["currency"] as? String ?? "EUR")
    }

    // MARK: - Rows

    struct Row {
        let metric: String
        let group: String
        let eventType: String?
        let zone: String?
        let tier: String?
        let paid: Decimal
    }

    /// Recursively gathers usage rows (objects with `billing_metric` + `value_paid`) — the
    /// categories nest them at different depths (`completion.models.X.input[]`,
    /// `libraries_api.pages.models.X.pages[]`, …).
    private static func collectRows(_ node: Any) -> [Row] {
        if let list = node as? [Any] { return list.flatMap(collectRows) }
        guard let dict = node as? [String: Any] else { return [] }
        if let metric = dict["billing_metric"] as? String,
           let paid = (dict["value_paid"] as? NSNumber)?.decimalValue {
            return [Row(
                metric: metric,
                group: dict["billing_group"] as? String ?? "",
                eventType: dict["event_type"] as? String,
                zone: dict["api_zone"] as? String,
                tier: dict["service_tier"] as? String,
                paid: paid
            )]
        }
        return dict.values.flatMap(collectRows)
    }

    // MARK: - Prices

    /// Unit prices keyed like the console's `getPriceForComponent` (metric, group, event type,
    /// zone); `service_tier` is preferred when it matches but not required.
    private struct PriceTable {
        private var byTier: [String: Decimal] = [:]
        private var byComponent: [String: Decimal] = [:]

        init(_ raw: [[String: Any]]) {
            for entry in raw {
                guard let metric = entry["billing_metric"] as? String,
                      let price = Self.decimal(entry["price"]) else { continue }
                let base = Self.key(metric, entry["billing_group"] as? String, entry["event_type"] as? String, entry["api_zone"] as? String)
                byTier[base + "|" + (entry["service_tier"] as? String ?? "")] = price
                if byComponent[base] == nil { byComponent[base] = price }
            }
        }

        func price(for row: Row) -> Decimal? {
            let base = Self.key(row.metric, row.group, row.eventType, row.zone)
            return byTier[base + "|" + (row.tier ?? "")] ?? byComponent[base]
        }

        private static func key(_ parts: String?...) -> String {
            parts.map { $0 ?? "" }.joined(separator: "|")
        }

        /// Prices arrive as strings in scientific notation (`"3.4E-9"`).
        private static func decimal(_ value: Any?) -> Decimal? {
            if let string = value as? String { return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
            return (value as? NSNumber)?.decimalValue
        }
    }
}
