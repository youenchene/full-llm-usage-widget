import Foundation

/// Raw shape of `GET /zen/go/v1/usage` — three windows, each with an integer `percent` (0–100)
/// and an ISO-8601 `resetsAt`.
private struct OpenCodeGoResponse: Decodable {
    struct Window: Decodable {
        let status: String?
        let percent: Int?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case status
            case percent
            case resetsAt
        }
    }
    struct Usage: Decodable {
        let rolling: Window?
        let weekly: Window?
        let monthly: Window?
    }
    let usage: Usage
}

/// Fetches OpenCode Go (quota) usage. `GET /zen/go/v1/usage` returns `rolling` (5-hour),
/// `weekly`, and `monthly` windows already normalized to an integer percent, so we map
/// `percent → used` (limit 100) and `resetsAt → LimitWindow.resetsAt` without any dollar ceiling.
struct OpenCodeGoFetcher: Sendable {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    func fetch(apiKey: String) async throws -> ProviderUsage {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await UsageHTTP.get(
            request,
            onUnauthorized: "OpenCode rejected the key — use a workspace API key (opencode.ai → workspace → Keys, format sk-…), and ensure the workspace has a Go subscription."
        )
        return try Self.parse(data)
    }

    /// Pure JSON → `ProviderUsage` mapping (no network), exposed for self-checks.
    static func parse(_ data: Data) throws -> ProviderUsage {
        let decoded: OpenCodeGoResponse
        do {
            decoded = try JSONDecoder().decode(OpenCodeGoResponse.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
        let windows: [LimitWindow] = [
            window(decoded.usage.rolling, label: "5h"),
            window(decoded.usage.weekly, label: "weekly"),
            window(decoded.usage.monthly, label: "monthly")
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw ProviderError.decoding("No usage windows in response") }

        let plan = Plan(
            id: "\(Provider.openCode.rawValue).go",
            provider: .openCode,
            name: "OpenCode Go",
            kind: .quota,
            limitWindows: windows
        )
        return ProviderUsage(provider: .openCode, plans: [plan], fetchedAt: Date())
    }

    private static func window(_ raw: OpenCodeGoResponse.Window?, label: String) -> LimitWindow? {
        guard let raw, let percent = raw.percent else { return nil }
        return LimitWindow(
            label: label,
            used: Double(percent),
            limit: 100,
            resetsAt: parseDate(raw.resetsAt)
        )
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
