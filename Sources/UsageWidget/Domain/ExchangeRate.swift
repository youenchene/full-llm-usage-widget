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

/// Pure currency math for normalizing spend between USD and EUR.
enum CurrencyMath {
    /// Convert an amount in `code` into `target` using `eurPerUSD` (EUR per 1 USD). Returns nil
    /// for a currency we can't convert, so the caller can skip it rather than fabricate a figure.
    static func convert(_ amount: Decimal, from code: String, to target: String, eurPerUSD: Decimal) -> Decimal? {
        switch (code.uppercased(), target.uppercased()) {
        case ("EUR", "EUR"), ("USD", "USD"):
            return amount
        case ("USD", "EUR"):
            return amount * eurPerUSD
        case ("EUR", "USD"):
            return amount / eurPerUSD
        default:
            return nil
        }
    }
}
