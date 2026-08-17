import Foundation

/// Wires the Domain model, Engine, Providers, and MenuBar together.
@MainActor
final class CompositionRoot {
    let store: UsageStore
    let scheduler: RefreshScheduler
    let statusBarController: StatusBarController

    init() {
        let cache = SnapshotCache(bundleIdentifier: AppInfo.bundleIdentifier)
        let credentials = CredentialStore(service: AppInfo.bundleIdentifier)

        let providers: [any UsageProvider] = [
            ClaudeProvider(tokens: credentials),
            CodexProvider(tokens: credentials),
            CopilotProvider(tokens: credentials)
            // Mistral is deferred: its usage/billing API (the Admin API) is Enterprise-only,
            // so there's no way to read spend on Pro/Free plans. Re-enable for Enterprise users:
            // MistralProvider(secrets: credentials)
        ]

        let store = UsageStore(providers: providers, cache: cache)
        store.loadSnapshot()

        self.store = store
        self.scheduler = RefreshScheduler(interval: .seconds(60)) {
            await store.refresh()
        }
        self.statusBarController = StatusBarController(store: store, providers: providers)
    }

    func start() {
        scheduler.start()
    }

    func stop() {
        scheduler.stop()
    }
}
