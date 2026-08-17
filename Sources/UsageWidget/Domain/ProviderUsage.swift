import Foundation

/// The normalized usage returned by a single `UsageProvider`, covering one or more `Plan`s.
struct ProviderUsage: Codable, Hashable, Sendable {
    let provider: Provider
    let plans: [Plan]
    let fetchedAt: Date
}
