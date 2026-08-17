import Foundation
import CryptoKit

/// In-process self-checks exercised by `run.sh --check` (and the packaged `--check` flag).
///
/// Phase 2 added PKCE + per-provider parsing checks; Phase 4 adds settings round-trip, threshold
/// classification, budget→progress, notification once-per-cycle, and menu-bar focus selection.
enum SelfCheck {
    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("PASS \(name)")
            } else {
                print("FAIL \(name)")
                failures += 1
            }
        }

        // Backoff: grows exponentially and caps at maxDelay.
        let policy = BackoffPolicy.standard
        check("backoff.initial", policy.delay(afterConsecutiveFailures: 0) == .seconds(5))
        check("backoff.grows", policy.delay(afterConsecutiveFailures: 1) == .seconds(10))
        check("backoff.caps", policy.delay(afterConsecutiveFailures: 20) == .seconds(900))
        check("backoff.seconds", policy.delaySeconds(afterConsecutiveFailures: 3) == 40)

        // Progress: clamps to 0...1 and handles a zero limit.
        check("progress.normal", Progress(used: 5, limit: 10).value == 0.5)
        check("progress.over-limit-clamps", Progress(used: 15, limit: 10).value == 1)
        check("progress.zero-limit", Progress(used: 0, limit: 0).value == 0)
        check("progress.negative-clamps", Progress(value: -0.5).value == 0)

        // PKCE: verifier/state lengths, and challenge == base64url(SHA256(verifier)).
        let pkce = PKCE.generate()
        check("pkce.verifier-length", pkce.verifier.count == 43)
        check("pkce.state-length", pkce.state.count == 43)
        let expectedChallenge = PKCE.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8))))
        check("pkce.challenge", pkce.challenge == expectedChallenge)
        check("pkce.verifier-distinct", pkce.verifier != pkce.challenge && pkce.verifier != pkce.state)

        // Parsing: each provider's pure JSON → ProviderUsage mapping.
        checkParsing(&failures)

        // Snapshot: JSON round-trip.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-widget-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = SnapshotCache(directory: dir)
        let plan = Plan(
            id: "opencode.go",
            provider: .openCode,
            name: "OpenCode Go",
            kind: .quota,
            limitWindows: [
                LimitWindow(
                    label: "rolling",
                    used: 42,
                    limit: 100,
                    resetsAt: Date(timeIntervalSince1970: 1_752_000_000)
                )
            ]
        )
        let snapshot = Snapshot(plans: [plan], fetchedAt: Date())
        do {
            try cache.save(snapshot)
            let loaded = cache.load()
            check("snapshot.roundtrip", loaded?.plans == snapshot.plans)
        } catch {
            print("FAIL snapshot.roundtrip: \(error)")
            failures += 1
        }

        // Settings, thresholds, budgets, focus, and notifications.
        checkSettings(&failures)
        checkNotifications(&failures)

        print(failures == 0 ? "Self-check OK" : "Self-check FAILED (\(failures) failure(s))")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Settings / thresholds / budget / focus

    private static func checkSettings(_ failures: inout Int) {
        func check(_ name: String, _ condition: Bool) {
            if condition { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-widget-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = SettingsState.default
        state.enabledProviders.remove(.gemini)
        state.budgets["scaleway"] = Budget(amount: Decimal(50), currencyCode: "EUR")
        state.menuBarFocus = .pinned(planID: "scaleway")
        state.thresholds = Thresholds(warning: 0.6, critical: 0.8)
        state.pollIntervalSeconds = 120

        let store = SettingsStore(directory: dir)
        do {
            try store.save(state)
            let loaded = store.load()
            check("settings.roundtrip", loaded == state)
            check("settings.focus-pinned", loaded?.menuBarFocus == .pinned(planID: "scaleway"))
            check("settings.budget", loaded?.budgets["scaleway"]?.amount == Decimal(50))
            check("settings.disabled", loaded?.enabledProviders.contains(.gemini) == false)
        } catch {
            print("FAIL settings.roundtrip: \(error)")
            failures += 1
        }

        // Threshold classification: warning/critical bands and their boundaries.
        let t = Thresholds(warning: 0.6, critical: 0.8)
        check("threshold.normal", t.level(for: 0.5) == .normal)
        check("threshold.warning", t.level(for: 0.7) == .warning)
        check("threshold.critical", t.level(for: 0.9) == .critical)
        check("threshold.warning-boundary", t.level(for: 0.6) == .warning)
        check("threshold.critical-boundary", t.level(for: 0.8) == .critical)

        // Budget → progress (ADR-0002): a spend plan renders progress only with a budget.
        let unbudgeted = Plan(
            id: "scaleway", provider: .scaleway, name: "Scaleway", kind: .spend,
            spent: Decimal(40), currencyCode: "EUR"
        )
        check("spend.no-budget-no-progress", unbudgeted.progress == nil)

        var budgeted = unbudgeted
        budgeted.budget = Budget(amount: Decimal(100), currencyCode: "EUR")
        check("spend.budget-progress", budgeted.progress?.value == 0.4)

        // Menu-bar focus: auto picks the most-urgent; pinned picks by id.
        let quota = Plan(
            id: "claude", provider: .claude, name: "Claude", kind: .quota,
            limitWindows: [LimitWindow(label: "5h", used: 50, limit: 100, resetsAt: nil)]
        )
        let all = [budgeted, quota]
        check("focus.auto-max", MenuBarSelection.progress(plans: all, focus: .auto) == quota.progress)
        check("focus.pinned", MenuBarSelection.progress(plans: all, focus: .pinned(planID: "scaleway")) == budgeted.progress)
        check("focus.pinned-missing", MenuBarSelection.progress(plans: all, focus: .pinned(planID: "nope")) == nil)
    }

    // MARK: - Near-limit notifications (once per window/reset cycle)

    private static func checkNotifications(_ failures: inout Int) {
        func check(_ name: String, _ condition: Bool) {
            if condition { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
        }

        final class RecordingPoster: NotificationPosting {
            var count = 0
            func post(title: String, body: String) { count += 1 }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-widget-notify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reset = Date(timeIntervalSince1970: 1_752_000_000)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let nearLimit = Plan(
            id: "claude", provider: .claude, name: "Claude", kind: .quota,
            limitWindows: [LimitWindow(label: "5h", used: 92, limit: 100, resetsAt: reset)]
        )
        let safe = Plan(
            id: "codex", provider: .codex, name: "Codex", kind: .quota,
            limitWindows: [LimitWindow(label: "5h", used: 20, limit: 100, resetsAt: reset)]
        )

        let poster = RecordingPoster()
        let notifier = NearLimitNotifier(poster: poster, store: NotificationCycleStore(directory: dir))

        notifier.check(plans: [safe], now: now)
        check("notify.below-threshold-silent", poster.count == 0)

        notifier.check(plans: [nearLimit], now: now)
        check("notify.crosses-once", poster.count == 1)

        notifier.check(plans: [nearLimit], now: now)
        check("notify.once-per-cycle", poster.count == 1)

        // A fresh notifier (simulating a relaunch) re-loads the persisted key and stays silent.
        let poster2 = RecordingPoster()
        let relaunched = NearLimitNotifier(poster: poster2, store: NotificationCycleStore(directory: dir))
        relaunched.check(plans: [nearLimit], now: now)
        check("notify.persisted-across-relaunch", poster2.count == 0)

        // A new reset window re-arms the notification.
        let nextReset = Date(timeIntervalSince1970: 1_752_100_000)
        let nextCycle = Plan(
            id: "claude", provider: .claude, name: "Claude", kind: .quota,
            limitWindows: [LimitWindow(label: "5h", used: 95, limit: 100, resetsAt: nextReset)]
        )
        notifier.check(plans: [nextCycle], now: now)
        check("notify.new-cycle-again", poster.count == 2)
    }

    // MARK: - Provider parsing

    private static func checkParsing(_ failures: inout Int) {
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("PASS \(name)")
            } else {
                print("FAIL \(name)")
                failures += 1
            }
        }

        // Claude: two windows (5h + weekly), utilization is a 0–100 percentage.
        let claudeJSON = #"""
        {"five_hour":{"utilization":42,"resets_at":"2026-08-17T20:12:00Z"},
         "seven_day":{"utilization":17,"resets_at":"2026-08-23T23:59:59Z"}}
        """#
        if let usage = try? ClaudeUsageFetcher.parse(Data(claudeJSON.utf8), plan: "claude_max") {
            let plan = usage.plans.first
            check("claude.parse.windows", plan?.limitWindows.count == 2)
            check("claude.parse.name", plan?.name == "Claude Max")
            check("claude.parse.5h", plan?.limitWindows.first(where: { $0.label == "5h" })?.used == 42)
            check("claude.parse.weekly", plan?.limitWindows.first(where: { $0.label == "weekly" })?.used == 17)
        } else {
            check("claude.parse", false)
        }

        // Codex: primary/secondary windows with epoch resets, plan from rate_limits.plan_type.
        let codexJSON = #"""
        {"rate_limits":{"primary":{"used_percent":55,"resets_at":1755000000},
                        "secondary":{"used_percent":20,"resets_at":1755500000},
                        "plan_type":"plus"}}
        """#
        if let usage = try? CodexUsageFetcher.parse(Data(codexJSON.utf8), planFallback: nil) {
            let plan = usage.plans.first
            check("codex.parse.windows", plan?.limitWindows.count == 2)
            check("codex.parse.name", plan?.name == "Codex Plus")
            check("codex.parse.5h", plan?.limitWindows.first(where: { $0.label == "5h" })?.used == 55)
            check("codex.parse.weekly", plan?.limitWindows.first(where: { $0.label == "weekly" })?.used == 20)
        } else {
            check("codex.parse", false)
        }

        // Copilot: monthly premium-request quota (entitlement − remaining).
        let copilotJSON = #"""
        {"copilot_plan":"business","quota_reset_date_utc":"2026-09-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":120}}}
        """#
        if let usage = try? CopilotUsageFetcher.parse(Data(copilotJSON.utf8)) {
            let window = usage.plans.first?.limitWindows.first
            check("copilot.parse.window", window?.label == "monthly")
            check("copilot.parse.used", window?.used == 180)
            check("copilot.parse.limit", window?.limit == 300)
            check("copilot.parse.name", usage.plans.first?.name == "Copilot Business")
        } else {
            check("copilot.parse", false)
        }

        // Mistral: sum of nested `cost` fields + top-level currency.
        let mistralJSON = #"""
        {"currency":"EUR",
         "completion":{"models":{"mistral-large":{"2026-08-17":[{"cost":1.25,"usage":100}]}}},
         "chat":{"models":{"mistral-large":{"2026-08-17":[{"cost":0.75,"usage":50}]}}}}
        """#
        if let usage = try? MistralUsageFetcher.parse(Data(mistralJSON.utf8)) {
            let plan = usage.plans.first
            let spent = plan?.spent.map { NSDecimalNumber(decimal: $0).doubleValue }
            check("mistral.parse.spent", spent == 2.0)
            check("mistral.parse.currency", plan?.currencyCode == "EUR")
            check("mistral.parse.kind", plan?.kind == .spend)
        } else {
            check("mistral.parse", false)
        }

        // Scaleway: sum `value` for "Generative APIs" records only (filtering other products).
        let scalewayJSON = #"""
        {"consumptions":[
           {"value":{"units":12,"nanos":340000000,"currency_code":"EUR"},
            "product_name":"Generative APIs"},
           {"value":{"units":5,"nanos":0,"currency_code":"EUR"},
            "product_name":"Object Storage"}
         ],
         "total_count":2}
        """#
        if let page = try? ScalewayUsageFetcher.parse(Data(scalewayJSON.utf8)) {
            let spent = NSDecimalNumber(decimal: page.spent).doubleValue
            check("scaleway.parse.spent", abs(spent - 12.34) < 0.0001)
            check("scaleway.parse.currency", page.currency == "EUR")
            check("scaleway.parse.total", page.totalCount == 2)
        } else {
            check("scaleway.parse", false)
        }

        // OpenCode Go: three windows (5h / weekly / monthly) as integer percents.
        let openCodeJSON = #"""
        {"usage":{
           "rolling":{"status":"ok","percent":42,"resetsAt":"2026-08-17T20:12:00.000Z"},
           "weekly":{"status":"ok","percent":17,"resetsAt":"2026-08-23T23:59:59.000Z"},
           "monthly":{"status":"ok","percent":3,"resetsAt":"2026-08-31T23:59:59.000Z"}}}
        """#
        if let usage = try? OpenCodeGoFetcher.parse(Data(openCodeJSON.utf8)) {
            let plan = usage.plans.first
            check("opencode.parse.windows", plan?.limitWindows.count == 3)
            check("opencode.parse.5h", plan?.limitWindows.first(where: { $0.label == "5h" })?.used == 42)
            check("opencode.parse.weekly", plan?.limitWindows.first(where: { $0.label == "weekly" })?.used == 17)
            check("opencode.parse.monthly", plan?.limitWindows.first(where: { $0.label == "monthly" })?.used == 3)
            check("opencode.parse.name", plan?.name == "OpenCode Go")
            check("opencode.parse.kind", plan?.kind == .quota)
        } else {
            check("opencode.parse", false)
        }

        // Claude billing: `amount` is cents (decimal string); sum across buckets.
        let claudeBillingJSON = #"""
        {"data":[
           {"results":[{"amount":"123.78912","currency":"USD"},{"amount":"10.0","currency":"USD"}]}
         ],
         "has_more":false}
        """#
        if let page = try? ClaudeBillingFetcher.parse(Data(claudeBillingJSON.utf8)) {
            check("claude.billing.cents", page.totalCents == 133.78912)
            let dollars = ClaudeBillingFetcher.dollars(cents: page.totalCents)
            check("claude.billing.dollars", NSDecimalNumber(decimal: dollars).doubleValue == 1.3378912)
        } else {
            check("claude.billing.parse", false)
        }
    }
}
