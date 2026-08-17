import Foundation
import Observation

/// The single source of truth for all Plan usage, backed by a last-good `Snapshot`.
@MainActor
@Observable
final class UsageStore {
    private(set) var plans: [Plan] = []
    private(set) var lastUpdatedAt: Date?
    private(set) var lastError: String?

    private let providers: [any UsageProvider]
    private let cache: SnapshotCache

    init(providers: [any UsageProvider], cache: SnapshotCache) {
        self.providers = providers
        self.cache = cache
    }

    /// Restore the last-good `Snapshot` so the widget renders instantly on launch.
    func loadSnapshot() {
        guard let snapshot = cache.load() else { return }
        plans = snapshot.plans
        lastUpdatedAt = snapshot.fetchedAt
    }

    /// Refresh every wired `UsageProvider`, then persist the last-good `Snapshot`.
    /// A failed provider never clears existing usage — it falls back to the last-good value.
    func refresh() async {
        for provider in providers {
            do {
                let usage = try await provider.fetchUsage()
                upsert(usage)
                lastError = nil
            } catch {
                lastError = "\(provider.provider.displayName): \(error.localizedDescription)"
            }
        }
        lastUpdatedAt = Date()
        do {
            try cache.save(Snapshot(plans: plans, fetchedAt: lastUpdatedAt ?? Date()))
        } catch {
            lastError = "Snapshot save failed: \(error.localizedDescription)"
        }
    }

    /// Replace this provider's existing plans with the freshly-fetched ones.
    private func upsert(_ usage: ProviderUsage) {
        var kept = plans.filter { $0.provider != usage.provider }
        kept.append(contentsOf: usage.plans)
        plans = kept
    }
}
