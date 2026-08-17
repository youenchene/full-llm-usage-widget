import Foundation

/// Remaining prepaid credit on a spend Plan (OpenCode Zen auto-reloads its balance).
struct Balance: Codable, Hashable, Sendable {
    let amount: Decimal
    let currencyCode: String
}
