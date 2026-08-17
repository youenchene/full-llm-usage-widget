import Foundation

/// Legacy request-count usage: the "monthly fast requests" quota — `gpt-4.numRequests` used against
/// `gpt-4.maxRequestUsage`, resetting at `startOfMonth`.
struct CursorLegacyUsage: Sendable {
    let fastRequestsUsed: Double
    let fastRequestsLimit: Double
    let startOfMonth: Date?

    /// The single monthly `LimitWindow` this model renders as. Used is a request count; the limit
    /// is the account's fast-request entitlement.
    var window: LimitWindow {
        LimitWindow(
            label: "monthly",
            used: fastRequestsUsed,
            limit: fastRequestsLimit,
            resetsAt: Self.nextMonth(after: startOfMonth)
        )
    }

    private static func nextMonth(after date: Date?) -> Date? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .month, value: 1, to: date)
    }
}

/// USD credit usage (newer accounts): the limit is a dollar credit, so the plan renders the
/// `totalPercentUsed` as a monthly progress toward 100%.
struct CursorCreditUsage: Sendable {
    let percentUsed: Double
    let resetAt: Date?

    var window: LimitWindow {
        LimitWindow(label: "monthly", used: percentUsed, limit: 100, resetsAt: resetAt)
    }
}

/// Fetches Cursor usage. Cursor has no public usage API, so we read its local auth token
/// (see `CursorStateDB`) and call the two endpoints Cursor's own client uses:
///
/// - **Legacy request-count** (`cursor.com/api/usage`): the "monthly fast requests" quota.
/// - **USD credit** (`api2.cursor.sh/…/GetCurrentPeriodUsage`): newer accounts, rendered as the
///   `totalPercentUsed` percentage.
///
/// Both are undocumented and version-dependent; the account's billing model is detected from the
/// response (legacy when `maxRequestUsage > 0`, else credit).
struct CursorUsageFetcher: Sendable {
    static let usageURL = URL(string: "https://cursor.com/api/usage")!
    static let creditURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    func fetch(accessToken: String, userId: String?, planBadge: String?) async throws -> ProviderUsage {
        // Legacy request-count model first (matches "monthly fast requests"); it needs the user id.
        if let userId, !userId.isEmpty {
            if let legacy = try await fetchLegacy(accessToken: accessToken, userId: userId) {
                return Self.makePlan(planBadge: planBadge, window: legacy.window)
            }
        }
        // Fall back to the USD credit model (Bearer-only, no user id needed).
        guard let credit = try await fetchCredit(accessToken: accessToken) else {
            throw ProviderError.decoding("Cursor returned no recognizable usage window.")
        }
        return Self.makePlan(planBadge: planBadge, window: credit.window)
    }

    // MARK: - Network

    private func fetchLegacy(accessToken: String, userId: String) async throws -> CursorLegacyUsage? {
        var components = URLComponents(url: Self.usageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user", value: userId)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WorkosCursorSessionToken=\(userId)::\(accessToken)", forHTTPHeaderField: "Cookie")
        let data = try await UsageHTTP.get(request)
        return try Self.parseUsage(data)
    }

    private func fetchCredit(accessToken: String) async throws -> CursorCreditUsage? {
        var request = URLRequest(url: Self.creditURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let data = try await UsageHTTP.get(request)
        return try Self.parseCredit(data)
    }

    // MARK: - Pure parsing (no network), exposed for self-checks

    /// Parse the legacy `cursor.com/api/usage` response. Returns nil when the account has no fast
    /// request quota (`maxRequestUsage` absent/zero) — i.e. it's on the USD credit model.
    static func parseUsage(_ data: Data) throws -> CursorLegacyUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Non-JSON Cursor usage response")
        }
        guard let gpt4 = json["gpt-4"] as? [String: Any],
              let limit = double(gpt4["maxRequestUsage"]), limit > 0 else {
            return nil
        }
        let used = double(gpt4["numRequests"]) ?? double(gpt4["numRequestsTotal"]) ?? 0
        return CursorLegacyUsage(
            fastRequestsUsed: used,
            fastRequestsLimit: limit,
            startOfMonth: parseISO8601(json["startOfMonth"] as? String)
        )
    }

    /// Parse the USD-credit `GetCurrentPeriodUsage` response. Returns nil when there's no usable
    /// percentage (e.g. an unexpected shape).
    static func parseCredit(_ data: Data) throws -> CursorCreditUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Non-JSON Cursor credit response")
        }
        guard let planUsage = json["planUsage"] as? [String: Any] else { return nil }
        let percent = double(planUsage["totalPercentUsed"])
            ?? double(planUsage["autoPercentUsed"])
            ?? Self.percent(limit: planUsage["limit"], used: planUsage["used"], remaining: planUsage["remaining"])
        guard let percent else { return nil }
        return CursorCreditUsage(
            percentUsed: min(max(percent, 0), 100),
            resetAt: epochMilliseconds(json["billingCycleEnd"])
        )
    }

    // MARK: - Mapping

    private static func makePlan(planBadge: String?, window: LimitWindow) -> ProviderUsage {
        let badge = PlanName.badge(from: planBadge)
        let plan = Plan(
            id: Provider.cursor.rawValue,
            provider: .cursor,
            name: badge.map { "Cursor \($0)" } ?? "Cursor",
            kind: .quota,
            limitWindows: [window]
        )
        return ProviderUsage(provider: .cursor, plans: [plan], fetchedAt: Date())
    }

    // MARK: - Decoding helpers

    private static func double(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func percent(limit: Any?, used: Any?, remaining: Any?) -> Double? {
        guard let limit = double(limit), limit > 0 else { return nil }
        if let used = double(used) { return used / limit * 100 }
        if let remaining = double(remaining) { return (limit - remaining) / limit * 100 }
        return nil
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func epochMilliseconds(_ any: Any?) -> Date? {
        guard let value = double(any), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
