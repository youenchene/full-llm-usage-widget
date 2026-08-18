import Foundation
import CryptoKit
import SQLite3

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
        checkCursorDatabase(&failures)
        checkCurrency(&failures)
        checkGeminiGCP(&failures)

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
        state.budgets["scaleway"] = Budget(amount: Decimal(50), currencyCode: "EUR")
        state.menuBarFocus = .pinned(planID: "scaleway")
        state.thresholds = Thresholds(warning: 0.6, critical: 0.8)
        state.pollIntervalSeconds = 120
        state.providerOrder = [.scaleway, .openCode, .claude, .codex, .copilot, .gemini, .mistral]
        state.displayCurrency = .usd

        let store = SettingsStore(directory: dir)
        do {
            try store.save(state)
            let loaded = store.load()
            check("settings.roundtrip", loaded == state)
            check("settings.focus-pinned", loaded?.menuBarFocus == .pinned(planID: "scaleway"))
            check("settings.budget", loaded?.budgets["scaleway"]?.amount == Decimal(50))
            check("settings.provider-order", loaded?.providerOrder.first == .scaleway)
            check("settings.currency", loaded?.displayCurrency == .usd)
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

    // MARK: - Currency conversion + quota average (menu-bar two-line label)

    private static func checkCurrency(_ failures: inout Int) {
        func check(_ name: String, _ condition: Bool) {
            if condition { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
        }

        let posix = Locale(identifier: "en_US_POSIX")
        let rate = Decimal(string: "0.9", locale: posix)!

        // Conversion: identity passes through; USD↔EUR converts; unknown currencies are skipped.
        check("currency.eur-identity", CurrencyMath.convert(Decimal(10), from: "EUR", to: "EUR", eurPerUSD: rate) == Decimal(10))
        check("currency.usd-identity", CurrencyMath.convert(Decimal(10), from: "USD", to: "USD", eurPerUSD: rate) == Decimal(10))
        check("currency.usd-to-eur", CurrencyMath.convert(Decimal(10), from: "USD", to: "EUR", eurPerUSD: rate) == Decimal(9))
        check("currency.eur-to-usd", CurrencyMath.convert(Decimal(9), from: "EUR", to: "USD", eurPerUSD: rate) == Decimal(10))
        check("currency.unknown-nil", CurrencyMath.convert(Decimal(10), from: "GBP", to: "EUR", eurPerUSD: rate) == nil)

        // Compact currency: cents are dropped once the amount exceeds 100.
        let big = Formatting.compactCurrency(Decimal(123.45), code: "EUR")
        let small = Formatting.compactCurrency(Decimal(12.34), code: "EUR")
        check("format.compact-big-no-cents", !big.contains(".") && !big.contains(","))
        check("format.compact-small-has-cents", small.contains(".") || small.contains(","))

        // Exchange rate parse (Frankfurter shape: base USD, rates.EUR).
        let frankfurter = #"{"amount":1.0,"base":"USD","date":"2026-08-17","rates":{"EUR":0.9212}}"#
        if let eur = try? ExchangeRateFetcher.parse(Data(frankfurter.utf8)) {
            check("rate.parse", abs(NSDecimalNumber(decimal: eur).doubleValue - 0.9212) < 0.0001)
        } else {
            check("rate.parse", false)
        }

        // Quota average: OpenCode Go monthly 40% + Codex weekly 20% → 30%.
        let go = Plan(
            id: "opencode.go", provider: .openCode, name: "OpenCode Go", kind: .quota,
            limitWindows: [
                LimitWindow(label: "5h", used: 10, limit: 100, resetsAt: nil),
                LimitWindow(label: "weekly", used: 20, limit: 100, resetsAt: nil),
                LimitWindow(label: "monthly", used: 40, limit: 100, resetsAt: nil)
            ]
        )
        let codex = Plan(
            id: "codex", provider: .codex, name: "Codex", kind: .quota,
            limitWindows: [
                LimitWindow(label: "5h", used: 55, limit: 100, resetsAt: nil),
                LimitWindow(label: "weekly", used: 20, limit: 100, resetsAt: nil)
            ]
        )
        check("quota.average", abs((MenuBarSelection.averageQuotaProgress(plans: [go, codex])?.value ?? -1) - 0.3) < 0.0001)
        check("quota.average-weekly-fallback", MenuBarSelection.averageQuotaProgress(plans: [codex])?.value == 0.2)
        check("quota.average-empty", MenuBarSelection.averageQuotaProgress(plans: []) == nil)

        // Codex often exposes only its "5h" window (no weekly); it must still count.
        let codex5hOnly = Plan(
            id: "codex", provider: .codex, name: "Codex", kind: .quota,
            limitWindows: [LimitWindow(label: "5h", used: 10, limit: 100, resetsAt: nil)]
        )
        check("quota.average-5h-fallback",
              abs((MenuBarSelection.averageQuotaProgress(plans: [go, codex5hOnly])?.value ?? -1) - 0.25) < 0.0001)
        check("quota.average-5h-only", MenuBarSelection.averageQuotaProgress(plans: [codex5hOnly])?.value == 0.1)

        // A spend plan is ignored by the quota average.
        let spend = Plan(
            id: "scaleway", provider: .scaleway, name: "Scaleway", kind: .spend,
            spent: Decimal(40), currencyCode: "EUR"
        )
        check("quota.average-ignores-spend", MenuBarSelection.averageQuotaProgress(plans: [go, spend])?.value == 0.4)
    }

    // MARK: - Gemini GCP billing export (BigQuery)

    private static func checkGeminiGCP(_ failures: inout Int) {
        func check(_ name: String, _ condition: Bool) {
            if condition { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
        }

        let posix = Locale(identifier: "en_US_POSIX")

        // Billing row aggregation: gross cost + credits, exact decimal arithmetic.
        let spendJSON = #"""
        {"kind":"bigquery#queryResponse","jobComplete":true,
         "rows":[{"f":[{"v":"12.34"},{"v":"-1.25"},{"v":"USD"},{"v":"1"}]}],"totalRows":"1"}
        """#
        do {
            let result = try GeminiGCPFetcher.parseQueryResponse(Data(spendJSON.utf8))
            let usage = try GeminiGCPFetcher.parseSpend(result)
            let plan = usage.plans.first
            check("gemini.gcp.parse.spent", plan?.spent == Decimal(string: "11.09", locale: posix))
            check("gemini.gcp.parse.currency", plan?.currencyCode == "USD")
            check("gemini.gcp.parse.kind", plan?.kind == .spend)
            check("gemini.gcp.parse.note", plan?.note == GeminiGCPFetcher.estimateNote)
            check("gemini.gcp.parse.fetchedAt", plan?.fetchedAt != nil)
        } catch {
            check("gemini.gcp.parse.spent", false)
        }

        // No rows → zero spend (not an error).
        do {
            let empty = try GeminiGCPFetcher.parseQueryResponse(Data(#"{"jobComplete":true}"#.utf8))
            let usage = try GeminiGCPFetcher.parseSpend(empty)
            check("gemini.gcp.parse.empty-zero", usage.plans.first?.spent == Decimal(0))
        } catch {
            check("gemini.gcp.parse.empty-zero", false)
        }

        // Mixed currencies are rejected (cannot aggregate across currencies).
        let mixedJSON = #"""
        {"jobComplete":true,"rows":[{"f":[{"v":"12.34"},{"v":"-1.25"},{"v":"USD"},{"v":"2"}]}]}
        """#
        do {
            let result = try GeminiGCPFetcher.parseQueryResponse(Data(mixedJSON.utf8))
            _ = try GeminiGCPFetcher.parseSpend(result)
            check("gemini.gcp.parse.mixed-currency-rejected", false)
        } catch ProviderError.decoding {
            check("gemini.gcp.parse.mixed-currency-rejected", true)
        } catch {
            check("gemini.gcp.parse.mixed-currency-rejected", false)
        }

        // Discovery result decoding: service descriptions + attributed cost.
        let discoveryJSON = #"""
        {"jobComplete":true,"rows":[
          {"f":[{"v":"Google Cloud Vertex AI"},{"v":"10.00"},{"v":"USD"}]},
          {"f":[{"v":"Gemini Code Assist"},{"v":"5.00"},{"v":"USD"}]}
        ]}
        """#
        do {
            let result = try GeminiGCPFetcher.parseQueryResponse(Data(discoveryJSON.utf8))
            let services = try GeminiGCPFetcher.parseDiscovery(result)
            check("gemini.gcp.parse.discovery-count", services.count == 2)
            check("gemini.gcp.parse.discovery-name", services.first?.service == "Google Cloud Vertex AI")
            check("gemini.gcp.parse.discovery-cost", services.first?.cost == Decimal(string: "10.00", locale: posix))
            check("gemini.gcp.parse.discovery-currency", services.first?.currency == "USD")
        } catch {
            check("gemini.gcp.parse.discovery", false)
        }

        // Malformed responses.
        do {
            _ = try GeminiGCPFetcher.parseQueryResponse(Data("not json".utf8))
            check("gemini.gcp.parse.non-json", false)
        } catch ProviderError.decoding {
            check("gemini.gcp.parse.non-json", true)
        } catch {
            check("gemini.gcp.parse.non-json", false)
        }

        do {
            let errorJSON = #"{"jobComplete":true,"errors":[{"message":"Access Denied: Table x"}]}"#
            _ = try GeminiGCPFetcher.parseQueryResponse(Data(errorJSON.utf8))
            check("gemini.gcp.parse.query-errors", false)
        } catch ProviderError.decoding {
            check("gemini.gcp.parse.query-errors", true)
        } catch {
            check("gemini.gcp.parse.query-errors", false)
        }

        do {
            let malformed = try GeminiGCPFetcher.parseQueryResponse(
                Data(#"{"jobComplete":true,"rows":[{"f":[{"v":"12.34"}]}]}"#.utf8)
            )
            _ = try GeminiGCPFetcher.parseSpend(malformed)
            check("gemini.gcp.parse.malformed-row", false)
        } catch ProviderError.decoding {
            check("gemini.gcp.parse.malformed-row", true)
        } catch {
            check("gemini.gcp.parse.malformed-row", false)
        }

        // Permission/auth failure mapping into the existing ProviderError vocabulary.
        check("gemini.gcp.errors.403-permission",
              GeminiGCPFetcher.mapHTTPError(status: 403, body: "") == .permissionDenied(
                "BigQuery permission denied — the service account needs roles/bigquery.jobUser and roles/bigquery.dataViewer on the project."
              ))
        check("gemini.gcp.errors.401-bad-credentials",
              GeminiGCPFetcher.mapHTTPError(status: 401, body: "") == .badCredentials(
                "Google rejected the service account credential — check the service account JSON."
              ))
        check("gemini.gcp.errors.404-table",
              GeminiGCPFetcher.mapHTTPError(status: 404, body: "") == .permissionDenied(
                "BigQuery table not found — verify the billing-export table identifier."
              ))
        check("gemini.gcp.errors.429-rate-limited",
              GeminiGCPFetcher.mapHTTPError(status: 429, body: "") == .rateLimited(retryAfter: nil))
        check("gemini.gcp.errors.400-not-found-table",
              GeminiGCPFetcher.mapHTTPError(status: 400, body: "Not found: Table x") == .permissionDenied(
                "BigQuery table not found — verify the billing-export table identifier."
              ))
        check("gemini.gcp.errors.500-transport",
              GeminiGCPFetcher.mapHTTPError(status: 500, body: "boom") == .transport("BigQuery HTTP 500: boom"))

        // Invalid service-account JSON → badCredentials.
        do {
            _ = try GoogleServiceAccountTokenFetcher.parseServiceAccount("not json")
            check("gemini.gcp.errors.invalid-service-account", false)
        } catch ProviderError.badCredentials {
            check("gemini.gcp.errors.invalid-service-account", true)
        } catch {
            check("gemini.gcp.errors.invalid-service-account", false)
        }

        // Table/project identifier validation (SQL-injection safety).
        check("gemini.gcp.table.valid",
              GeminiGCPFetcher.isValidTableIdentifier("my-project.my_dataset.gcp_billing_export_v1_ABC123"))
        check("gemini.gcp.table.rejects-backtick",
              !GeminiGCPFetcher.isValidTableIdentifier("my-project.my_dataset.`evil`"))
        check("gemini.gcp.table.rejects-semicolon",
              !GeminiGCPFetcher.isValidTableIdentifier("my-project.my_dataset.x; DROP"))
        check("gemini.gcp.table.rejects-two-parts",
              !GeminiGCPFetcher.isValidTableIdentifier("my-project.my_dataset"))
        check("gemini.gcp.project.valid", GeminiGCPFetcher.isValidProjectID("my-gcp-project"))
        check("gemini.gcp.project.rejects-uppercase", !GeminiGCPFetcher.isValidProjectID("MyGCPProject"))

        // JWT structure: header + claims are base64url (no padding chars); a garbage key fails
        // cleanly as badCredentials instead of crashing.
        let account = GoogleServiceAccountTokenFetcher.ServiceAccount(
            clientEmail: "svc@project.iam.gserviceaccount.com",
            privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----",
            tokenURI: GoogleServiceAccountTokenFetcher.defaultTokenURI
        )
        let header = GoogleServiceAccountTokenFetcher.jwtHeader()
        check("gemini.gcp.jwt.header-base64url",
              !header.contains("+") && !header.contains("/") && !header.contains("="))
        if let claims = try? GoogleServiceAccountTokenFetcher.jwtClaims(account: account, now: 1_752_000_000) {
            check("gemini.gcp.jwt.claims-base64url",
                  !claims.contains("+") && !claims.contains("/") && !claims.contains("="))
        } else {
            check("gemini.gcp.jwt.claims-base64url", false)
        }
        do {
            _ = try GoogleServiceAccountTokenFetcher.signRS256(Data("data".utf8), privateKeyPEM: "not a key")
            check("gemini.gcp.jwt.bad-key", false)
        } catch ProviderError.badCredentials {
            check("gemini.gcp.jwt.bad-key", true)
        } catch {
            check("gemini.gcp.jwt.bad-key", false)
        }

        // Stale Snapshot fallback: a persisted last-good snapshot renders even when the provider
        // would fail — the engine never clears existing usage on a failed refresh.
        MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("usage-widget-gemini-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let cache = SnapshotCache(directory: dir)
            let settings = SettingsModel(store: SettingsStore(directory: dir))
            let rates = ExchangeRateStore(cache: ExchangeRateCache(directory: dir))
            let plan = Plan(
                id: GeminiGCPFetcher.planID, provider: .gemini, name: GeminiGCPFetcher.planName,
                kind: .spend, spent: Decimal(string: "11.09", locale: posix), currencyCode: "USD",
                note: GeminiGCPFetcher.estimateNote, fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
            )
            try? cache.save(Snapshot(plans: [plan], fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)))

            let store = UsageStore(
                providers: [FailingGeminiProvider()],
                cache: cache,
                settings: settings,
                rates: rates
            )
            store.loadSnapshot()
            check("gemini.gcp.stale-snapshot-restored", store.visiblePlans.first?.spent == Decimal(string: "11.09", locale: posix))
            check("gemini.gcp.stale-snapshot-note", store.visiblePlans.first?.note == GeminiGCPFetcher.estimateNote)
        }
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

        // Mistral console: embedded api_budget block → monthly quota window (percent of 100).
        let mistralConsoleHTML = #"""
        <html><body>
        <script>self.__next_f.push([1,"...\"budget\":{\"api_budget\":{\"usage_percentage\":7.078156333333333,\"initial_budget\":25.5,\"currency\":\"EUR\",\"reset_at\":\"2026-09-01T00:00:00Z\",\"payg_enabled\":false}}..."])</script>
        </body></html>
        """#
        if let usage = try? MistralConsoleFetcher.parse(Data(mistralConsoleHTML.utf8)) {
            let plan = usage.plans.first
            let window = plan?.limitWindows.first
            check("mistral.console.parse.kind", plan?.kind == .quota)
            check("mistral.console.parse.name", plan?.name == "Mistral API")
            check("mistral.console.parse.window-label", window?.label == "monthly")
            check("mistral.console.parse.window-used", abs((window?.used ?? 0) - 7.078156333333333) < 0.0001)
            check("mistral.console.parse.window-limit", window?.limit == 100)
            check("mistral.console.parse.window-resets", window?.resetsAt != nil)
            check("mistral.console.parse.note", plan?.note?.contains("included monthly") == true)
        } else {
            check("mistral.console.parse", false)
        }

        // Expired session (login page, no budget block) → unauthorized.
        do {
            _ = try MistralConsoleFetcher.parse(Data("<html>login page</html>".utf8))
            check("mistral.console.parse.expired-unauthorized", false)
        } catch ProviderError.unauthorized {
            check("mistral.console.parse.expired-unauthorized", true)
        } catch {
            check("mistral.console.parse.expired-unauthorized", false)
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

        // OpenCode Zen: balance/monthlyUsage are micro-cents; monthlyLimit is already dollars.
        let posix = Locale(identifier: "en_US_POSIX")
        let zenHTML = #"""
        <!DOCTYPE html><html><body>
        <script>window.__BILLING__ = { balance:12420811571, monthlyUsage:461288722, monthlyLimit:null }</script>
        </body></html>
        """#
        if let billing = try? OpenCodeZenFetcher.parse(html: zenHTML) {
            let plan = billing.makePlan()
            check("opencode.zen.parse.kind", plan.kind == .spend)
            check("opencode.zen.parse.spent", plan.spent == Decimal(string: "4.61288722", locale: posix))
            check("opencode.zen.parse.balance", plan.balance?.amount == Decimal(string: "124.20811571", locale: posix))
            check("opencode.zen.parse.currency", plan.currencyCode == "USD")
            check("opencode.zen.parse.budget-nil", plan.budget == nil)
        } else {
            check("opencode.zen.parse", false)
        }

        // OpenCode Zen with a monthly limit → budget is that dollar amount (no division).
        let zenBudgetHTML = #"""
        <script>balance:10000000000, monthlyUsage:0, monthlyLimit:100</script>
        """#
        if let billing = try? OpenCodeZenFetcher.parse(html: zenBudgetHTML) {
            let plan = billing.makePlan()
            check("opencode.zen.parse.budget", plan.budget?.amount == Decimal(100))
            check("opencode.zen.parse.budget-spent", plan.spent == Decimal(0))
        } else {
            check("opencode.zen.parse.budget", false)
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

        // Cursor legacy: fast-request quota (`gpt-4` used/limit + startOfMonth) → monthly window.
        let cursorLegacyJSON = #"""
        {"gpt-4":{"numRequests":42,"maxRequestUsage":500},"startOfMonth":"2026-08-01T00:00:00.000Z"}
        """#
        if let usage = try? CursorUsageFetcher.parseUsage(Data(cursorLegacyJSON.utf8)) {
            check("cursor.legacy.used", usage.fastRequestsUsed == 42)
            check("cursor.legacy.limit", usage.fastRequestsLimit == 500)
            check("cursor.legacy.window-label", usage.window.label == "monthly")
            check("cursor.legacy.window-used", usage.window.used == 42)
            check("cursor.legacy.window-resets", usage.window.resetsAt != nil)
        } else {
            check("cursor.legacy.parse", false)
        }

        // Cursor legacy with no fast-request quota → nil (account is on the credit model).
        let cursorNoQuotaJSON = #"""
        {"gpt-4":{"numRequests":900,"maxRequestUsage":null},"startOfMonth":"2026-08-01T00:00:00.000Z"}
        """#
        let noQuota = try? CursorUsageFetcher.parseUsage(Data(cursorNoQuotaJSON.utf8))
        check("cursor.legacy.nil-when-unlimited", noQuota == nil)

        // Cursor credit: totalPercentUsed → monthly window (used percent, limit 100).
        let cursorCreditJSON = #"""
        {"billingCycleEnd":"1767225600000","planUsage":{"limit":2000,"remaining":800,"used":1200,"totalPercentUsed":60}}
        """#
        if let usage = try? CursorUsageFetcher.parseCredit(Data(cursorCreditJSON.utf8)) {
            check("cursor.credit.percent", usage.percentUsed == 60)
            check("cursor.credit.window-limit", usage.window.limit == 100)
            check("cursor.credit.window-used", usage.window.used == 60)
            check("cursor.credit.window-resets", usage.window.resetsAt != nil)
        } else {
            check("cursor.credit.parse", false)
        }
    }

    // MARK: - Cursor local database reader (SQLite round-trip)

    private static func checkCursorDatabase(_ failures: inout Int) {
        func check(_ name: String, _ condition: Bool) {
            if condition { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-widget-cursor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("state.vscdb")
        createCursorTestDatabase(at: dbURL)

        do {
            let token = try CursorStateDB.readString(key: "cursorAuth/accessToken", at: dbURL)
            let membership = try CursorStateDB.readString(key: "cursorAuth/stripeMembershipType", at: dbURL)
            let missing = try CursorStateDB.readString(key: "cursorAuth/nonexistent", at: dbURL)
            check("cursor.db.token", token == "jwt-token-abc")
            check("cursor.db.membership", membership == "pro")
            check("cursor.db.missing-key-nil", missing == nil)
        } catch {
            print("FAIL cursor.db.read: \(error)")
            failures += 1
        }

        // A nonexistent database path → permissionDenied (not a crash).
        let bogus = dir.appendingPathComponent("does-not-exist.vscdb")
        do {
            _ = try CursorStateDB.readString(key: "cursorAuth/accessToken", at: bogus)
            check("cursor.db.missing-file", false)
        } catch ProviderError.permissionDenied {
            check("cursor.db.missing-file", true)
        } catch {
            check("cursor.db.missing-file", false)
        }
    }

    /// Build a minimal `state.vscdb`-shaped DB (an `ItemTable` key/value store) for the reader test.
    private static func createCursorTestDatabase(at url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return }
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value BLOB);", nil, nil, nil)
        func insert(_ key: String, _ value: String) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK,
                  let stmt else { return }
            _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, CursorStateDB.sqliteTransient) }
            _ = value.withCString { sqlite3_bind_text(stmt, 2, $0, -1, CursorStateDB.sqliteTransient) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        insert("cursorAuth/accessToken", "jwt-token-abc")
        insert("cursorAuth/stripeMembershipType", "pro")
        sqlite3_close(db)
    }
}

/// A provider that always fails, used to verify last-good data survives a failed refresh.
private struct FailingGeminiProvider: UsageProvider {
    let provider = Provider.gemini
    let minimumPollInterval: TimeInterval = 60

    func authState() async -> ProviderAuthState { .signedIn }
    func signIn() async throws -> SignInContinuation { .completed }
    func signOut() async {}
    func fetchUsage() async throws -> ProviderUsage {
        throw ProviderError.permissionDenied("no access")
    }
}
