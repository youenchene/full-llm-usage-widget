import Foundation

/// Codex (OpenAI) OAuth via the public Codex CLI client. Uses a loopback redirect on
/// 127.0.0.1:1455 captured by `LoopbackOAuthServer`. Token exchange is form-urlencoded; refresh
/// is JSON. The id_token JWT carries `chatgpt_account_id` + `chatgpt_plan_type`.
/// Constants verified against the openai/codex source.
struct CodexOAuthClient: Sendable {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeBase = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let loopbackPort: UInt16 = 1455
    static let scopes = "openid profile email offline_access"
    static let originator = "llm_usage_widget"

    func makeAuthorizeURL(pkce: PKCEChallenge) -> URL {
        var components = URLComponents(string: Self.authorizeBase)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: Self.originator),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        return components.url!
    }

    func exchange(code: String, pkce: PKCEChallenge) async throws -> OAuthToken {
        let form: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": pkce.verifier
        ]
        let response = try await OAuthHTTP.send(formRequest(form))
        return makeToken(from: response, previousRefresh: nil, previousAccount: nil)
    }

    func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else { throw ProviderError.unauthorized }
        let body: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ]
        let response = try await OAuthHTTP.send(jsonRequest(body))
        return makeToken(from: response, previousRefresh: refreshToken, previousAccount: token.accountId)
    }

    // MARK: - Requests

    private func formRequest(_ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        return request
    }

    private func jsonRequest(_ body: [String: String]) -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeToken(from response: OAuthTokenResponse, previousRefresh: String?, previousAccount: String?) -> OAuthToken {
        let claims = Self.decodeClaims(jwt: response.id_token ?? response.access_token)
        return OAuthToken(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(response.expires_in ?? 3600),
            accountId: claims.accountId ?? previousAccount,
            planType: claims.planType
        )
    }

    // MARK: - Helpers

    static func formEncode(_ dict: [String: String]) -> String {
        dict.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlFormValueAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlFormValueAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    }

    /// Decode `chatgpt_account_id` and `chatgpt_plan_type` from a JWT payload.
    static func decodeClaims(jwt: String) -> (accountId: String?, planType: String?) {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return (nil, nil) }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        let accountId = (auth?["chatgpt_account_id"] as? String) ?? (json["chatgpt_account_id"] as? String)
        let planType = (auth?["chatgpt_plan_type"] as? String) ?? (json["chatgpt_plan_type"] as? String)
        return (accountId, planType)
    }
}
