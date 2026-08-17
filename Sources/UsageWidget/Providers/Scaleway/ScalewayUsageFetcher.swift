import Foundation

/// Fetches Scaleway monthly inference spend from the Billing v2beta1 consumptions endpoint.
///
/// `GET /billing/v2beta1/consumptions` (auth via `X-Auth-Token`, a secret key) returns one
/// consumption line per SKU. Monthly "Generative APIs" (slug `inference`) spend is the sum of
/// `value` over the current `billing_period` where `product_name == "Generative APIs"`.
struct ScalewayUsageFetcher: Sendable {
    static let consumptionsURL = URL(string: "https://api.scaleway.com/billing/v2beta1/consumptions")!
    /// The human-readable product name for inference spend (slug `inference`). There is no
    /// product filter on the endpoint, so we filter client-side on this exact string.
    static let inferenceProductName = "Generative APIs"

    func fetch(secretKey: String, organizationId: String) async throws -> ProviderUsage {
        let period = Self.currentBillingPeriod()
        var spent = Decimal(0)
        var currency = "EUR"
        var totalCount = 0
        var collected = 0
        var page = 1
        let pageSize = 100

        repeat {
            var components = URLComponents(url: Self.consumptionsURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "organization_id", value: organizationId),
                URLQueryItem(name: "billing_period", value: period),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize)),
                URLQueryItem(name: "order_by", value: "updated_at_desc")
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setValue(secretKey, forHTTPHeaderField: "X-Auth-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let data = try await UsageHTTP.get(
                request,
                onUnauthorized: "Scaleway rejected the secret key — check the X-Auth-Token and that the key has BillingReadOnly scope."
            )
            let pageResult = try Self.parse(data)
            spent += pageResult.spent
            currency = pageResult.currency
            totalCount = pageResult.totalCount
            collected += pageResult.returnedCount
            page += 1
        } while collected < totalCount

        let plan = Plan(
            id: Provider.scaleway.rawValue,
            provider: .scaleway,
            name: "Scaleway",
            kind: .spend,
            spent: spent,
            currencyCode: currency
        )
        return ProviderUsage(provider: .scaleway, plans: [plan], fetchedAt: Date())
    }

    /// One page of consumptions, reduced to the inference-spend figure plus pagination info.
    struct Page: Sendable {
        let spent: Decimal
        let currency: String
        let returnedCount: Int
        let totalCount: Int
    }

    /// Pure JSON → per-page sum of inference spend (exposed for self-checks).
    static func parse(_ data: Data) throws -> Page {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
        let inference = decoded.consumptions.filter { $0.productName == inferenceProductName }
        let spent = inference.reduce(Decimal(0)) { $0 + money($1.value) }
        let currency = inference.compactMap(\.value?.currencyCode).first?.uppercased() ?? "EUR"
        return Page(
            spent: spent,
            currency: currency,
            returnedCount: decoded.consumptions.count,
            totalCount: decoded.totalCount ?? decoded.consumptions.count
        )
    }

    /// `google.type.Money` → `Decimal` (`units` + `nanos / 1e9`).
    private static func money(_ value: Response.Consumption.Money?) -> Decimal {
        guard let value else { return 0 }
        return Decimal(value.units) + Decimal(value.nanos) / Decimal(1_000_000_000)
    }

    /// Current month as `YYYY-MM` (the default `billing_period`).
    static func currentBillingPeriod(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// Raw shape of `ListConsumptionsResponse` (from `scaleway-sdk-go`; JSON tags = field names).
private struct Response: Decodable {
    struct Consumption: Decodable {
        struct Money: Decodable {
            let units: Int64
            let nanos: Int
            let currencyCode: String?
            enum CodingKeys: String, CodingKey {
                case units
                case nanos
                case currencyCode = "currency_code"
            }
        }
        let value: Money?
        let productName: String?
        enum CodingKeys: String, CodingKey {
            case value
            case productName = "product_name"
        }
    }
    let consumptions: [Consumption]
    let totalCount: Int?
    enum CodingKeys: String, CodingKey {
        case consumptions
        case totalCount = "total_count"
    }
}
