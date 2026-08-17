import Foundation

/// Fetches GitHub Copilot quota from the undocumented `copilot_internal/user` endpoint (the one the
/// editors use). Returns a monthly premium-request quota; chat/completions are typically unlimited.
struct CopilotUsageFetcher: Sendable {
    static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    func fetch(accessToken: String) async throws -> ProviderUsage {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FullLLMUsageWidget", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA
        let data = try await UsageHTTP.get(request)
        return try Self.parse(data)
    }

    /// Pure JSON → `ProviderUsage` mapping (no network). Decoded leniently because the shape shifts
    /// across plans / billing modes.
    static func parse(_ data: Data) throws -> ProviderUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Non-JSON Copilot response")
        }
        let rawPlan = json["copilot_plan"] as? String
        let reset = parseDate((json["quota_reset_date_utc"] as? String) ?? (json["quota_reset_date"] as? String))

        var window: LimitWindow
        if let snapshots = json["quota_snapshots"] as? [String: Any],
           let premium = snapshots["premium_interactions"] as? [String: Any] {
            let unlimited = (premium["unlimited"] as? Bool) ?? false
            if unlimited {
                window = LimitWindow(label: "monthly", used: 0, limit: 0, resetsAt: reset, unlimited: true)
            } else {
                let entitlement = doubleValue(premium["entitlement"]) ?? 0
                let remaining = doubleValue(premium["remaining"]) ?? doubleValue(premium["quota_remaining"]) ?? 0
                if entitlement > 0 {
                    window = LimitWindow(
                        label: "monthly",
                        used: max(0, entitlement - remaining),
                        limit: entitlement,
                        resetsAt: reset
                    )
                } else if let percentRemaining = doubleValue(premium["percent_remaining"]) {
                    window = LimitWindow(
                        label: "monthly",
                        used: 100 - percentRemaining,
                        limit: 100,
                        resetsAt: reset
                    )
                } else {
                    window = LimitWindow(label: "monthly", used: 0, limit: 0, resetsAt: reset, unlimited: true)
                }
            }
        } else {
            // Unknown / credits-based plan — show as uncapped rather than failing.
            window = LimitWindow(label: "monthly", used: 0, limit: 0, resetsAt: reset, unlimited: true)
        }

        let badge = PlanName.badge(from: rawPlan)
        let plan = Plan(
            id: Provider.copilot.rawValue,
            provider: .copilot,
            name: badge.map { "Copilot \($0)" } ?? "Copilot",
            kind: .quota,
            limitWindows: [window]
        )
        return ProviderUsage(provider: .copilot, plans: [plan], fetchedAt: Date())
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let dayOnly = DateFormatter()
        dayOnly.dateFormat = "yyyy-MM-dd"
        dayOnly.timeZone = TimeZone(identifier: "UTC")
        return dayOnly.date(from: string)
    }
}
