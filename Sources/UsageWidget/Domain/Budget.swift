import Foundation

/// A user-set monthly currency ceiling applied to a spend Plan so it can render as a percentage.
struct Budget: Codable, Hashable, Sendable {
    let amount: Decimal
    let currencyCode: String
}
