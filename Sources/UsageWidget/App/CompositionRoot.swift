import Foundation

/// Wires the Domain model, Engine, and MenuBar together.
@MainActor
final class CompositionRoot {
    let store: UsageStore
    let scheduler: RefreshScheduler
    let statusBarController: StatusBarController

    init() {
        let cache = SnapshotCache(bundleIdentifier: AppInfo.bundleIdentifier)

        let store = UsageStore(providers: [], cache: cache)
        store.loadSnapshot()

        self.store = store
        self.scheduler = RefreshScheduler(interval: .seconds(300)) {
            await store.refresh()
        }
        self.statusBarController = StatusBarController()
    }

    func start() {
        scheduler.start()
    }

    func stop() {
        scheduler.stop()
    }
}
