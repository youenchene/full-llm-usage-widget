import Foundation

/// Periodically refreshes the `UsageStore` on a fixed interval.
///
/// Per-provider intervals and exponential backoff are wired in Phase 2; this skeleton
/// runs a single fixed-interval loop against every provider.
@MainActor
final class RefreshScheduler {
    private let interval: Duration
    private let onRefresh: () async -> Void
    private var task: Task<Void, Never>?

    init(interval: Duration, onRefresh: @escaping () async -> Void) {
        self.interval = interval
        self.onRefresh = onRefresh
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.onRefresh()
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
