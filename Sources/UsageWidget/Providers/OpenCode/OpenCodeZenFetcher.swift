import Foundation

/// Parsed OpenCode Zen billing figures, already converted to dollars.
///
/// The console serves these server-side-rendered on `GET /workspace/{id}/billing`, inlining raw
/// integers in the HTML: `balance` and `monthlyUsage` are micro-cents, `monthlyLimit` is already
/// an integer dollar amount. `ZenBilling` carries the *converted* values so callers never see raw
/// units.
struct ZenBilling: Sendable {
    /// Remaining prepaid credit (auto-reloads; see CONTEXT.md `Balance`).
    let balance: Decimal
    /// Amount spent this month (raw micro-cents ÷ 100_000_000).
    let monthlyUsage: Decimal
    /// A user-set monthly spend ceiling, in dollars (`nil` when no budget is set).
    let monthlyLimit: Decimal?

    /// Build the spend Plan this billing data represents.
    func makePlan() -> Plan {
        Plan(
            id: "opencode.zen",
            provider: .openCode,
            name: "OpenCode Zen",
            kind: .spend,
            balance: Balance(amount: balance, currencyCode: "USD"),
            spent: monthlyUsage,
            currencyCode: "USD",
            budget: monthlyLimit.map { Budget(amount: $0, currencyCode: "USD") }
        )
    }
}

/// Fetches OpenCode Zen (spend) usage by scraping the console billing page with the user's
/// `opencode.ai` session cookie. There is no API-key endpoint for the Zen balance — the console
/// serves it server-side-rendered, with the raw integers inlined in the HTML (see
/// docs/spike-findings.md). The cookie has no refresh flow: the user re-pastes it when it expires.
struct OpenCodeZenFetcher: Sendable {
    /// `balance`/`monthlyUsage` are micro-cents → dollars = raw / 100_000_000.
    static let microCentsPerDollar: Decimal = 100_000_000

    static let baseURL = "https://opencode.ai"

    /// Browser User-Agent — the console SSR only returns the billing page to browser-like clients.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    private static let session = URLSession(configuration: .ephemeral)

    func fetch(cookie: String, workspaceID: String) async throws -> ProviderUsage {
        let url = URL(string: "\(Self.baseURL)/workspace/\(workspaceID)/billing")!
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

        // 401/403, or a 302 the session followed onto the authorize page, means the cookie is
        // stale. There is no refresh flow — the user re-copies the cookie from opencode.ai.
        if http.statusCode == 401 || http.statusCode == 403
            || response.url?.path().contains("/auth/authorize") == true {
            throw ProviderError.badCredentials("session expired — re-copy the auth cookie from opencode.ai")
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

        let billing = try Self.parse(html: html)
        return ProviderUsage(provider: .openCode, plans: [billing.makePlan()], fetchedAt: Date())
    }

    /// Pure HTML → `ZenBilling` (no network), exposed for self-checks.
    static func parse(html: String) throws -> ZenBilling {
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
    private static func parseNewSSR(_ html: String) -> ZenBilling? {
        guard let marker = html.range(of: "billing.get") else { return nil }
        let prefix = html[html.startIndex..<marker.lowerBound]
        guard let hydration = prefix.range(of: "$R[", options: .backwards) else { return nil }
        return fields(in: String(html[hydration.lowerBound...])).flatMap(ZenBilling.init)
    }

    /// (b) Simple SSR: grep the whole HTML for `balance`/`monthlyUsage`/`monthlyLimit` numeric
    ///     assignments. `monthlyLimit:null` won't match the numeric pattern → treated as nil.
    private static func parseSimpleSSR(_ html: String) -> ZenBilling? {
        fields(in: html).flatMap(ZenBilling.init)
    }

    /// (c) data-slot markup: the console renders each figure as a `data-slot` label/value pair.
    ///     Best-effort last resort for markup reshuffles; values are already human-formatted
    ///     dollar strings.
    private static func parseDataSlots(_ html: String) -> ZenBilling? {
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
        return ZenBilling(balance: balance, monthlyUsage: monthlyUsage, monthlyLimit: monthlyLimit)
    }

    // MARK: - Field extraction

    /// Matches `balance:12420811571` / `monthlyUsage:461288722` / `monthlyLimit:100` (or `null`,
    /// which is deliberately skipped). Group 1 = field name, group 2 = integer.
    private static let fieldPattern = #"\b(balance|monthlyLimit|monthlyUsage)\s*:\s*(-?\d+)\b"#

    private static func fields(in text: String) -> ZenRawFields? {
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
        return ZenRawFields(
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

/// Raw, un-converted billing integers extracted from the HTML. Converted by `ZenBilling.init`.
private struct ZenRawFields {
    let balanceMicroCents: Int64
    let monthlyUsageMicroCents: Int64
    let monthlyLimitDollars: Int64?
}

private extension ZenBilling {
    init(_ raw: ZenRawFields) {
        balance = OpenCodeZenFetcher.dollars(microCents: raw.balanceMicroCents)
        monthlyUsage = OpenCodeZenFetcher.dollars(microCents: raw.monthlyUsageMicroCents)
        monthlyLimit = raw.monthlyLimitDollars.map { Decimal($0) }
    }
}
