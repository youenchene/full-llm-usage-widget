import Foundation

/// The load-bearing seam: every Provider conforms to this protocol.
///
/// Each conformer owns its own authentication and fetcher, and returns a normalized
/// `ProviderUsage`. Adding a provider is one new module with zero changes to the engine
/// (see ADR-0003).
protocol UsageProvider: Sendable {
    /// The `Provider` this fetcher authenticates against.
    var provider: Provider { get }

    /// Fetch the latest usage, normalized into a `ProviderUsage`.
    func fetchUsage() async throws -> ProviderUsage
}
