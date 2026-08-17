import Foundation

/// Wires the Domain model, Engine, Providers, MenuBar, Settings, and Notifications together.
@MainActor
final class CompositionRoot {
    let store: UsageStore
    let scheduler: RefreshScheduler
    let statusBarController: StatusBarController
    let settings: SettingsModel
    private let notificationPoster: UserNotificationPoster

    init() {
        let cache = SnapshotCache(bundleIdentifier: AppInfo.bundleIdentifier)
        let credentials = CredentialStore(service: AppInfo.bundleIdentifier)
        let settings = SettingsModel(store: SettingsStore(bundleIdentifier: AppInfo.bundleIdentifier))

        let providers: [any UsageProvider] = [
            ClaudeProvider(tokens: credentials),
            CodexProvider(tokens: credentials),
            CopilotProvider(tokens: credentials),
            ScalewayProvider(secrets: credentials),
            OpenCodeProvider(secrets: credentials),
            CursorProvider(secrets: credentials)
            // Mistral is deferred: its usage/billing API (the Admin API) is Enterprise-only,
            // so there's no way to read spend on Pro/Free plans. Re-enable for Enterprise users:
            // MistralProvider(secrets: credentials)
            // Gemini is deferred: no public usage endpoint (see docs/spike-findings.md — private
            // Antigravity backend). OpenCode Zen now ships inside OpenCodeProvider (two Plans).
            // Cursor (Phase 5) reads its local state.vscdb — Full Disk Access, opt-in, disabled by
            // default (see docs/cursor-full-disk-access.md).
        ]

        let poster = UserNotificationPoster()
        let notifier = NearLimitNotifier(
            poster: poster,
            store: NotificationCycleStore(bundleIdentifier: AppInfo.bundleIdentifier)
        )

        let store = UsageStore(providers: providers, cache: cache, settings: settings, notifier: notifier)
        store.loadSnapshot()

        self.settings = settings
        self.store = store
        self.notificationPoster = poster
        self.scheduler = RefreshScheduler(interval: { settings.pollInterval }) {
            await store.refresh()
        }
        self.statusBarController = StatusBarController(store: store, providers: providers, settings: settings)
    }

    func start() {
        scheduler.start()
        // Capture the poster locally so the Task doesn't cross into `self` (a MainActor class).
        let poster = notificationPoster
        Task { await poster.authorize() }
    }

    func stop() {
        scheduler.stop()
    }
}
