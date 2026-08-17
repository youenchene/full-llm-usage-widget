import Foundation

/// Periodically refreshes the `UsageStore` on a configurable interval. The interval is read fresh
/// each loop so a settings change is picked up without restarting.
@MainActor
final class RefreshScheduler {
    private let interval: () -> Duration
    private let onRefresh: () async -> Void
    private var task: Task<Void, Never>?

    init(interval: @escaping () -> Duration, onRefresh: @escaping () async -> Void) {
        self.interval = interval
        self.onRefresh = onRefresh
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.onRefresh()
                do {
                    try await Task.sleep(for: self.interval())
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
