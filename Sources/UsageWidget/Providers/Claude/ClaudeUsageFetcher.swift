import Foundation

/// Raw shape of `GET /api/oauth/usage` — utilization is a 0–100 percentage; resets_at is ISO-8601.
private struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
    }
    let fiveHour: Window?
    let sevenDay: Window?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

/// Fetches Claude subscription usage. The `User-Agent: claude-code/<version>` header is REQUIRED —
/// without it the endpoint rate-limits aggressively.
struct ClaudeUsageFetcher: Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let clientVersion = "2.1.0"

    /// `plan` is the raw plan string from `ClaudeProfileFetcher` (the usage endpoint carries none).
    func fetch(accessToken: String, plan: String? = nil) async throws -> ProviderUsage {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(Self.clientVersion)", forHTTPHeaderField: "User-Agent")

        let data = try await UsageHTTP.get(request)
        return try Self.parse(data, plan: plan)
    }

    /// Pure JSON → `ProviderUsage` mapping (no network), exposed for self-checks.
    static func parse(_ data: Data, plan: String? = nil) throws -> ProviderUsage {
        let decoded: ClaudeUsageResponse
        do {
            decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
        let windows = map(decoded)
        guard !windows.isEmpty else { throw ProviderError.decoding("No usage windows in response") }

        let badge = PlanName.badge(from: plan)
        let plan = Plan(
            id: Provider.claude.rawValue,
            provider: .claude,
            name: badge.map { "Claude \($0)" } ?? "Claude",
            kind: .quota,
            limitWindows: windows
        )
        return ProviderUsage(provider: .claude, plans: [plan], fetchedAt: Date())
    }

    private static func map(_ response: ClaudeUsageResponse) -> [LimitWindow] {
        func window(_ raw: ClaudeUsageResponse.Window?, _ label: String) -> LimitWindow? {
            guard let raw, let utilization = raw.utilization else { return nil }
            return LimitWindow(
                label: label,
                used: utilization,
                limit: 100,
                resetsAt: parseDate(raw.resetsAt)
            )
        }
        return [
            window(response.fiveHour, "5h"),
            window(response.sevenDay, "weekly")
        ].compactMap { $0 }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
