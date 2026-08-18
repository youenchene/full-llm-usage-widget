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
        let rates = ExchangeRateStore(bundleIdentifier: AppInfo.bundleIdentifier)

        let providers: [any UsageProvider] = [
            ClaudeProvider(tokens: credentials),
            CodexProvider(tokens: credentials),
            CopilotProvider(tokens: credentials),
            ScalewayProvider(secrets: credentials),
            OpenCodeProvider(secrets: credentials),
            GeminiProvider(secrets: credentials, settings: settings),
            MistralProvider(secrets: credentials),
            CursorProvider(secrets: credentials)
            // Mistral: two auth methods — an admin API key (spend, Enterprise only) and a console
            // session cookie (included monthly usage quota, any plan; see
            // docs/mistral-console-scrape.md).
            // Gemini's quota mode (AI Studio / Antigravity) is deferred: no public usage endpoint
            // (see docs/spike-findings.md). The GCP billing-export spend mode above is the only
            // Gemini connection today (see docs/gemini-gcp-billing.md).
            // Cursor (Phase 5) reads its local state.vscdb — Full Disk Access, opt-in, disabled by
            // default (see docs/cursor-full-disk-access.md).
        ]

        let poster = UserNotificationPoster()
        let notifier = NearLimitNotifier(
            poster: poster,
            store: NotificationCycleStore(bundleIdentifier: AppInfo.bundleIdentifier)
        )

        let store = UsageStore(providers: providers, cache: cache, settings: settings, notifier: notifier, rates: rates)
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
