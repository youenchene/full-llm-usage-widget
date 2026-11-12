import Foundation

/// Raw shape of `GET /zen/go/v1/usage`: three windows, each with a `percent` (0–100), a `status`
/// (`ok` | `rate-limited`) and an ISO-8601 `resetsAt`.
private struct OpenCodeGoResponse: Decodable {
    struct Window: Decodable {
        let status: String?
        let percent: Double?
        let resetsAt: String?
    }
    struct Usage: Decodable {
        let rolling: Window?
        let weekly: Window?
        let monthly: Window?
    }
    let usage: Usage
}

/// Fetches the OpenCode Go subscription (quota) allowance. The endpoint still lives at
/// `/zen/go/v1/usage` after the Zen → Console rename, and returns `rolling` (5-hour), `weekly`
/// and `monthly` windows already normalized to a percent. We map `percent → used` (limit 100).
/// A `rate-limited` window is blocked until it resets, so it renders as full.
struct OpenCodeGoFetcher: Sendable {
    static let usageURL = URL(string: "\(OpenCodeConsole.origin)/zen/go/v1/usage")!
    /// `openCode.go` (the Provider raw value): the ID cached snapshots already carry.
    static let planID = "\(Provider.openCode.rawValue).go"
    static let planName = "OpenCode Go subscription"

    /// The Go Plan, or `nil` when the workspace has no Go subscription (the endpoint answers 403).
    func fetch(credential: OpenCodeCredential) async throws -> Plan? {
        let request = OpenCodeConsole.request(Self.usageURL, credential: credential, workspaceHeader: "x-opencode-org-id")
        guard let data = try await OpenCodeConsole.getOptional(request) else { return nil }
        return try Self.parse(data).plans.first
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
            id: planID,
            provider: .openCode,
            name: planName,
            kind: .quota,
            limitWindows: windows
        )
        return ProviderUsage(provider: .openCode, plans: [plan], fetchedAt: Date())
    }

    private static func window(_ raw: OpenCodeGoResponse.Window?, label: String) -> LimitWindow? {
        guard let raw, let percent = raw.percent else { return nil }
        let blocked = raw.status == "rate-limited"
        return LimitWindow(
            label: label,
            used: blocked ? max(percent, 100) : percent,
            limit: 100,
            resetsAt: OpenCodeConsole.parseDate(raw.resetsAt)
        )
    }
}
