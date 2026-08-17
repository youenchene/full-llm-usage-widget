import Foundation

/// Fetches the USD → EUR exchange rate from Frankfurter (ECB reference rates; free, no key).
struct ExchangeRateFetcher: Sendable {
    static let url = URL(string: "https://api.frankfurter.app/latest?from=USD&to=EUR")!

    private struct Response: Decodable {
        struct Rates: Decodable {
            let EUR: Double
        }
        let rates: Rates
    }

    func fetch() async throws -> Decimal {
        var request = URLRequest(url: Self.url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await UsageHTTP.get(request)
        return try Self.parse(data)
    }

    /// Pure JSON → `eurPerUSD` (no network), exposed for self-checks.
    static func parse(_ data: Data) throws -> Decimal {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
        guard decoded.rates.EUR > 0 else {
            throw ProviderError.decoding("Non-positive EUR rate")
        }
        return Decimal(decoded.rates.EUR)
    }
}
