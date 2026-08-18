import Foundation

/// Formatting helpers for plan cards (currency + percentages).
enum Formatting {
    static func currency(_ amount: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(code)"
    }

    /// Currency for the compact menu-bar label: cents are dropped once the amount exceeds 100.
    static func compactCurrency(_ amount: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        if amount > 100 {
            formatter.maximumFractionDigits = 0
            formatter.minimumFractionDigits = 0
        }
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(code)"
    }

    /// Integer percentage from a 0–1 fraction, clamped to 0–100.
    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }
}
