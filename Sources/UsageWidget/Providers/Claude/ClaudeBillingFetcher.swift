import Foundation

/// Fetches Claude organization spend from the admin Cost Report API.
///
/// `GET /v1/organizations/cost_report` (auth via `x-api-key`, an **Admin** key) returns per-day
/// buckets whose `results[]` carry an `amount` (a decimal string in **cents**) and a `currency`
/// (always "USD" on this endpoint). We sum every `amount` across buckets and pages, then divide
/// by 100 for a dollar figure.
struct ClaudeBillingFetcher: Sendable {
    static let costReportURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    static let anthropicVersion = "2023-06-01"

    func fetch(apiKey: String) async throws -> ProviderUsage {
        let now = Date()
        let start = Self.monthStart(now)
        var totalCents = 0.0
        var nextPage: String?
        repeat {
            var components = URLComponents(url: Self.costReportURL, resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "starting_at", value: Self.iso(start)),
                URLQueryItem(name: "ending_at", value: Self.iso(now)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let nextPage { items.append(URLQueryItem(name: "page", value: nextPage)) }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let data = try await UsageHTTP.get(
                request,
                onUnauthorized: "Claude admin API key rejected — use an Admin key (platform.claude.com → Settings → Admin keys)."
            )
            let page = try Self.parse(data)
            totalCents += page.totalCents
            nextPage = page.hasNext ? page.nextPage : nil
        } while nextPage != nil

        let plan = Plan(
            id: "\(Provider.claude.rawValue).api",
            provider: .claude,
            name: "Claude API",
            kind: .spend,
            spent: Self.dollars(cents: totalCents),
            currencyCode: "USD"
        )
        return ProviderUsage(provider: .claude, plans: [plan], fetchedAt: Date())
    }

    /// Pure parse of one page → total cents + pagination info (exposed for self-checks).
    static func parse(_ data: Data) throws -> (totalCents: Double, hasNext: Bool, nextPage: String?) {
        struct Response: Decodable {
            struct Bucket: Decodable {
                struct Result: Decodable {
                    let amount: String?
                }
                let results: [Result]?
            }
            let data: [Bucket]
            let hasMore: Bool?
            let nextPage: String?
            enum CodingKeys: String, CodingKey {
                case data
                case hasMore = "has_more"
                case nextPage = "next_page"
            }
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }

        var total = 0.0
        for bucket in response.data {
            for result in bucket.results ?? [] {
                if let amount = result.amount, let cents = Double(amount) { total += cents }
            }
        }
        return (total, response.hasMore ?? false, response.nextPage)
    }

    static func dollars(cents: Double) -> Decimal {
        Decimal(string: String(cents / 100)) ?? Decimal(cents / 100)
    }

    // MARK: - Date helpers

    static func monthStart(_ date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
