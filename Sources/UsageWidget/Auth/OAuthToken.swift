import Foundation

/// The app's own stored OAuth credentials for a provider. Persisted in the Keychain only.
struct OAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var accountId: String?   // Codex: chatgpt_account_id (for the ChatGPT-Account-Id header)
    var planType: String?    // cached plan badge (Claude profile plan / Codex JWT plan_type)

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// True when the access token is within `skew` of expiry (or already expired).
    func needsRefresh(skew: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-skew)
    }
}
