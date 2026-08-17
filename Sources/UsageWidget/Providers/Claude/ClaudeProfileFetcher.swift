import Foundation

/// Fetches the Claude account profile to learn the subscription plan.
///
/// `GET /api/oauth/usage` carries no plan info at all, so the plan badge ("Max" / "Pro" / …) comes
/// from `GET /api/oauth/profile` instead — the same endpoint Claude Code reads. The plan rarely
/// changes, so `ClaudeProvider` caches the result on the stored token and calls this only once
/// (after sign-in / the first poll), not on every refresh cycle.
struct ClaudeProfileFetcher: Sendable {
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private struct Profile: Decodable {
        struct Account: Decodable {
            let hasClaudeMax: Bool?
            let hasClaudePro: Bool?
            enum CodingKeys: String, CodingKey {
                case hasClaudeMax = "has_claude_max"
                case hasClaudePro = "has_claude_pro"
            }
        }
        struct Organization: Decodable {
            let organizationType: String?
            enum CodingKeys: String, CodingKey { case organizationType = "organization_type" }
        }
        let account: Account?
        let organization: Organization?
    }

    /// Returns the raw plan string (e.g. `"claude_max"`), or nil if it can't be determined.
    func fetchRawPlan(accessToken: String) async throws -> String? {
        var request = URLRequest(url: Self.profileURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(ClaudeUsageFetcher.clientVersion)", forHTTPHeaderField: "User-Agent")

        let data = try await UsageHTTP.get(request)
        return Self.parsePlan(data)
    }

    /// Pure JSON → raw-plan mapping (no network), exposed for self-checks. Prefers the
    /// organization's `organization_type`, falling back to the account's `has_claude_*` booleans.
    static func parsePlan(_ data: Data) -> String? {
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return nil }
        if let type = profile.organization?.organizationType,
           !type.trimmingCharacters(in: .whitespaces).isEmpty {
            return type
        }
        if profile.account?.hasClaudeMax == true { return "claude_max" }
        if profile.account?.hasClaudePro == true { return "claude_pro" }
        return nil
    }
}
