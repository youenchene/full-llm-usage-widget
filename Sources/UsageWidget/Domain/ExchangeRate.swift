import Foundation

/// A cached USD → EUR conversion factor (EUR per 1 USD) plus when it was fetched.
///
/// The spend plans denominate in either USD or EUR today, so a single USD rate is all the
/// menu-bar € total needs.
struct ExchangeRate: Codable, Hashable, Sendable {
    /// How many EUR one USD costs.
    let eurPerUSD: Decimal
    let fetchedAt: Date
}

/// Pure currency math for normalizing spend into EUR.
enum CurrencyMath {
    /// Convert an amount in `code` into EUR using `eurPerUSD`. Returns nil for a currency we
    /// can't convert, so the caller can skip it rather than fabricate a euro figure.
    static func toEUR(amount: Decimal, code: String, eurPerUSD: Decimal) -> Decimal? {
        switch code.uppercased() {
        case "EUR": return amount
        case "USD": return amount * eurPerUSD
        default: return nil
        }
    }
}
