import Foundation

/// Parsed OpenCode Console billing figures, already converted to dollars.
///
/// The console serves these server-side-rendered on its billing page, inlining raw integers in
/// the HTML: `balance` and `monthlyUsage` are micro-cents, `monthlyLimit` is already an integer
/// dollar amount. `ConsoleBilling` carries the *converted* values so callers never see raw units.
struct ConsoleBilling: Sendable {
    /// Remaining prepaid credit (auto-reloads; see CONTEXT.md `Balance`).
    let balance: Decimal
    /// Amount spent this month (raw micro-cents ÷ 100_000_000).
    let monthlyUsage: Decimal
    /// A user-set monthly spend ceiling, in dollars (`nil` when no budget is set).
    let monthlyLimit: Decimal?

    /// Build the spend Plan this billing data represents (used when no bearer credential gives us
    /// budgets; otherwise only `balance` is merged into the budgets Plan).
    func makePlan() -> Plan {
        Plan(
            id: OpenCodeConsoleBalanceFetcher.planID,
            provider: .openCode,
            name: OpenCodeConsoleBalanceFetcher.planName,
            kind: .spend,
            balance: Balance(amount: balance, currencyCode: "USD"),
            spent: monthlyUsage,
            currencyCode: "USD",
            budget: monthlyLimit.map { Budget(amount: $0, currencyCode: "USD") }
        )
    }
}

/// Reads the OpenCode Console (formerly Zen) credit **balance** by scraping the billing page with
/// the user's `opencode.ai` session cookie. Optional: the Console API has no documented balance
/// endpoint, so this is the only source of `Balance`. Spend and budgets come from the bearer API
/// (`OpenCodeBudgetsFetcher`). The cookie has no refresh flow: the user re-pastes it when it
/// expires (see docs/opencode-console.md).
struct OpenCodeConsoleBalanceFetcher: Sendable {
    /// Internal ID kept from the Zen era (a literal, unlike Go's `openCode.go`) so saved budgets
    /// and snapshots keep working.
    static let planID = "opencode.zen"
    static let planName = "OpenCode Console"

    /// `balance`/`monthlyUsage` are micro-cents → dollars = raw / 100_000_000.
    static let microCentsPerDollar: Decimal = 100_000_000

    /// Billing page candidates, newest first: the Console moved under `/console` (Settings ›
    /// Billing); the pre-rename `/workspace/{id}/billing` path is kept as a fallback.
    static func billingURLs(workspaceID: String) -> [URL] {
        [
            URL(string: "\(OpenCodeConsole.server)/\(workspaceID)/settings/billing"),
            URL(string: "\(OpenCodeConsole.origin)/workspace/\(workspaceID)/billing")
        ].compactMap { $0 }
    }

    /// Browser User-Agent — the console SSR only returns the billing page to browser-like clients.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    private static let session = URLSession(configuration: .ephemeral)

    /// Fetch the billing figures, trying each billing page candidate until one parses.
    func fetch(cookie: String, workspaceID: String) async throws -> ConsoleBilling {
        var lastError: Error = ProviderError.decoding("No billing page found")
        for url in Self.billingURLs(workspaceID: workspaceID) {
            do {
                return try await fetch(url: url, cookie: cookie)
            } catch ProviderError.badCredentials(let message) {
                throw ProviderError.badCredentials(message)  // a stale cookie fails every candidate
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetch(url: URL, cookie: String) async throws -> ConsoleBilling {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("auth=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.decoding("Non-HTTP response")
        }

        // 401/403, or a 302 the session followed onto a sign-in page, means the cookie is stale.
        // There is no refresh flow — the user re-copies the cookie from opencode.ai.
        if http.statusCode == 401 || http.statusCode == 403
            || response.url?.path().contains("/auth/") == true {
            throw ProviderError.badCredentials("Console session expired — re-copy the auth cookie from opencode.ai")
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else {
            throw ProviderError.transport("HTTP \(http.statusCode)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.decoding("Non-UTF8 billing page")
        }

        return try Self.parse(html: html)
    }

    /// Pure HTML → `ConsoleBilling` (no network), exposed for self-checks.
    static func parse(html: String) throws -> ConsoleBilling {
        if let billing = parseNewSSR(html) { return billing }
        if let billing = parseSimpleSSR(html) { return billing }
        if let billing = parseDataSlots(html) { return billing }
        throw ProviderError.decoding("No billing figures found in the OpenCode page")
    }

    /// `micro-cents → dollars`.
    static func dollars(microCents: Int64) -> Decimal {
        Decimal(microCents) / microCentsPerDollar
    }

    // MARK: - Parse strategies (in fallback order)

    /// (a) SolidStart `$R[...]` hydration assignment for the `billing.get` server function.
    ///     Scope to that payload, then grep the three fields (avoids unrelated `balance` tokens
    ///     elsewhere on the page).
    private static func parseNewSSR(_ html: String) -> ConsoleBilling? {
        guard let marker = html.range(of: "billing.get") else { return nil }
        let prefix = html[html.startIndex..<marker.lowerBound]
        guard let hydration = prefix.range(of: "$R[", options: .backwards) else { return nil }
        return fields(in: String(html[hydration.lowerBound...])).flatMap(ConsoleBilling.init)
    }

    /// (b) Simple SSR: grep the whole HTML for `balance`/`monthlyUsage`/`monthlyLimit` numeric
    ///     assignments. `monthlyLimit:null` won't match the numeric pattern → treated as nil.
    private static func parseSimpleSSR(_ html: String) -> ConsoleBilling? {
        fields(in: html).flatMap(ConsoleBilling.init)
    }

    /// (c) data-slot markup: the console renders each figure as a `data-slot` label/value pair.
    ///     Best-effort last resort for markup reshuffles; values are already human-formatted
    ///     dollar strings.
    private static func parseDataSlots(_ html: String) -> ConsoleBilling? {
        guard let labelRegex = try? NSRegularExpression(pattern: #"data-slot="billing-label"[^>]*>([^<]+)<"#),
              let valueRegex = try? NSRegularExpression(pattern: #"data-slot="billing-value"[^>]*>([^<]+)<"#) else {
            return nil
        }
        let ns = html as NSString
        let labels = labelRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let values = valueRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var balance: Decimal?
        var monthlyUsage: Decimal?
        var monthlyLimit: Decimal?

        for (labelMatch, valueMatch) in zip(labels, values) {
            guard let labelRange = Range(labelMatch.range(at: 1), in: html),
                  let valueRange = Range(valueMatch.range(at: 1), in: html) else { continue }
            let label = String(html[labelRange]).lowercased()
            let value = String(html[valueRange])
            guard let amount = decimal(fromDisplayValue: value) else { continue }
            switch label {
            case "balance": balance = amount
            case "monthly usage", "monthly_usage", "usage", "spent this month": monthlyUsage = amount
            case "monthly limit", "monthly_limit", "budget", "limit": monthlyLimit = amount
            default: break
            }
        }

        guard let balance, let monthlyUsage else { return nil }
        return ConsoleBilling(balance: balance, monthlyUsage: monthlyUsage, monthlyLimit: monthlyLimit)
    }

    // MARK: - Field extraction

    /// Matches `balance:12420811571` / `monthlyUsage:461288722` / `monthlyLimit:100` (or `null`,
    /// which is deliberately skipped). Group 1 = field name, group 2 = integer.
    private static let fieldPattern = #"\b(balance|monthlyLimit|monthlyUsage)\s*:\s*(-?\d+)\b"#

    private static func fields(in text: String) -> ConsoleRawFields? {
        guard let regex = try? NSRegularExpression(pattern: fieldPattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var balance: Int64?
        var monthlyUsage: Int64?
        var monthlyLimit: Int64?
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let value = Int64(String(text[valueRange]))
            switch String(text[keyRange]) {
            case "balance": balance = value
            case "monthlyUsage": monthlyUsage = value
            case "monthlyLimit": monthlyLimit = value
            default: break
            }
        }
        guard let balance, let monthlyUsage else { return nil }
        return ConsoleRawFields(
            balanceMicroCents: balance,
            monthlyUsageMicroCents: monthlyUsage,
            monthlyLimitDollars: monthlyLimit
        )
    }

    /// Parse a human-formatted currency value (e.g. "$124.21") into a `Decimal` of dollars.
    private static func decimal(fromDisplayValue value: String) -> Decimal? {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }
}

/// Raw, un-converted billing integers extracted from the HTML. Converted by `ConsoleBilling.init`.
private struct ConsoleRawFields {
    let balanceMicroCents: Int64
    let monthlyUsageMicroCents: Int64
    let monthlyLimitDollars: Int64?
}

private extension ConsoleBilling {
    init(_ raw: ConsoleRawFields) {
        balance = OpenCodeConsoleBalanceFetcher.dollars(microCents: raw.balanceMicroCents)
        monthlyUsage = OpenCodeConsoleBalanceFetcher.dollars(microCents: raw.monthlyUsageMicroCents)
        monthlyLimit = raw.monthlyLimitDollars.map { Decimal($0) }
    }
}
