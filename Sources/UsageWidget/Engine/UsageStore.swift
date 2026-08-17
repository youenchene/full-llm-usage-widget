import Foundation
import Observation

/// The single source of truth for all Plan usage, backed by a last-good `Snapshot`.
@MainActor
@Observable
final class UsageStore {
    private(set) var plans: [Plan] = []
    private(set) var lastUpdatedAt: Date?
    private(set) var errors: [Provider: String] = [:]
    private(set) var authStates: [Provider: ProviderAuthState] = [:]
    private(set) var globalError: String?

    private let providers: [any UsageProvider]
    private let cache: SnapshotCache
    private let backoff = BackoffPolicy.standard

    /// Per-provider refresh timing: when it may next be polled, and its recent failure count.
    private struct ProviderState {
        var nextAllowedAt: Date = .distantPast
        var consecutiveFailures: Int = 0
    }
    private var states: [Provider: ProviderState] = [:]

    init(providers: [any UsageProvider], cache: SnapshotCache) {
        self.providers = providers
        self.cache = cache
    }

    /// The single most-urgent Plan's `Progress`, for the menu-bar label. Plans without a
    /// computable Progress (e.g. spend with no Budget) are ignored.
    var mostUrgentProgress: Progress? {
        plans.compactMap(\.progress).max()
    }

    /// Restore the last-good `Snapshot` so the widget renders instantly on launch.
    func loadSnapshot() {
        guard let snapshot = cache.load() else { return }
        plans = snapshot.plans
        lastUpdatedAt = snapshot.fetchedAt
    }

    /// Refresh every wired `UsageProvider`, then persist the last-good `Snapshot`.
    ///
    /// Each provider is gated by its `minimumPollInterval` and an exponential backoff on failure.
    /// A failed provider never clears existing usage — it falls back to the last-good value and
    /// records a per-provider error for the UI.
    func refresh() async {
        let now = Date()

        for provider in providers {
            let id = provider.provider
            var state = states[id] ?? ProviderState()
            guard now >= state.nextAllowedAt else { continue }

            do {
                let usage = try await provider.fetchUsage()
                upsert(usage)
                state.consecutiveFailures = 0
                state.nextAllowedAt = now.addingTimeInterval(provider.minimumPollInterval)
                errors[id] = nil
            } catch {
                state.consecutiveFailures += 1
                state.nextAllowedAt = now.addingTimeInterval(
                    backoff.delaySeconds(afterConsecutiveFailures: state.consecutiveFailures)
                )
                errors[id] = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            }
            states[id] = state
        }

        // Refresh auth state so the UI can flip between "sign in" and plan cards.
        for provider in providers {
            authStates[provider.provider] = await provider.authState()
        }

        lastUpdatedAt = now
        do {
            try cache.save(Snapshot(plans: plans, fetchedAt: now))
            globalError = nil
        } catch {
            globalError = "Snapshot save failed: \(error.localizedDescription)"
        }
    }

    /// Merge this provider's freshly-fetched plans into the store by plan `id`.
    ///
    /// Plans in the batch replace same-id plans; a provider's plans *not* in this batch (e.g. a
    /// Claude billing plan when only the subscription fetch succeeded) keep their last-good value.
    private func upsert(_ usage: ProviderUsage) {
        let incoming = Dictionary(usage.plans.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let old = Dictionary(
            plans.filter { $0.provider == usage.provider }.map { ($0.id, $0) },
            uniquingKeysWith: { $1 }
        )
        var merged = plans.filter { $0.provider != usage.provider }
        for id in Set(old.keys).union(incoming.keys).sorted() {
            if let plan = incoming[id] ?? old[id] {
                merged.append(plan)
            }
        }
        plans = merged
    }

    /// Sign a provider out: clear its credentials, drop its plans, and persist the change so a
    /// stale card doesn't linger across launches.
    func signOut(_ provider: any UsageProvider) async {
        await provider.signOut()
        plans.removeAll { $0.provider == provider.provider }
        authStates[provider.provider] = .signedOut
        errors[provider.provider] = nil
        try? cache.save(Snapshot(plans: plans, fetchedAt: lastUpdatedAt ?? Date()))
    }
}
