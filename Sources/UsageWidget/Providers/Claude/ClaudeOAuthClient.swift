import Foundation

/// Claude (Anthropic) OAuth via the Claude Code public client. Uses the paste-the-code flow:
/// the browser shows a `<code>#<state>` string the user pastes back (Anthropic rejects arbitrary
/// loopback redirects). Constants verified against community Claude Code OAuth implementations.
struct ClaudeOAuthClient: Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    func makeAuthorizeURL(pkce: PKCEChallenge) -> URL {
        var components = URLComponents(string: Self.authorizeBase)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        return components.url!
    }

    /// Exchange the pasted "code#state" string for tokens.
    func exchange(pastedCode raw: String, pkce: PKCEChallenge) async throws -> OAuthToken {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? ""
        let returnedState = parts.count > 1 ? parts[1] : ""
        guard !code.isEmpty else { throw OAuthError.invalidResponse }
        if !returnedState.isEmpty, returnedState != pkce.state { throw OAuthError.stateMismatch }

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": returnedState.isEmpty ? pkce.state : returnedState,
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "code_verifier": pkce.verifier
        ]
        let response = try await OAuthHTTP.send(jsonRequest(body))
        return makeToken(from: response, previousRefresh: nil)
    }

    func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else { throw ProviderError.unauthorized }
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ]
        let response = try await OAuthHTTP.send(jsonRequest(body))
        return makeToken(from: response, previousRefresh: refreshToken)
    }

    private func jsonRequest(_ body: [String: String]) -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeToken(from response: OAuthTokenResponse, previousRefresh: String?) -> OAuthToken {
        OAuthToken(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(response.expires_in ?? 3600),
            accountId: nil,
            planType: nil
        )
    }
}
