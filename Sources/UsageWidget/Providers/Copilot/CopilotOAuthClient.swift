import Foundation

/// GitHub Copilot OAuth via the **device flow** (the same client the editors use): the app shows a
/// short user code, the user enters it at github.com/login/device, and we poll for the token.
/// The Copilot usage endpoint accepts the plain GitHub user token (no JWT exchange needed).
struct CopilotOAuthClient: Sendable {
    static let clientID = "Iv1.b507a08c87ecfe98"
    static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    struct DeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    func requestDeviceCode() async throws -> DeviceCode {
        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("client_id=\(Self.clientID)".utf8)
        let (data, response) = try await OAuthHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                  body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Poll until the user authorizes, honoring the server's interval / slow_down, until expiry.
    func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> OAuthToken {
        var delay = max(interval, 5)
        var elapsed = 0
        while elapsed < expiresIn {
            try await Task.sleep(for: .seconds(delay))
            elapsed += delay
            switch try await pollOnce(deviceCode: deviceCode) {
            case .token(let token): return token
            case .pending: continue
            case .slowDown: delay += 5
            }
        }
        throw OAuthError.timeout
    }

    func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else { throw ProviderError.unauthorized }
        let body = "client_id=\(Self.clientID)&grant_type=refresh_token&refresh_token=\(refreshToken)"
        let json = try await postForm(body)
        guard let accessToken = json["access_token"] as? String else { throw ProviderError.unauthorized }
        return makeToken(accessToken: accessToken, json: json, previousRefresh: refreshToken)
    }

    // MARK: - Private

    private enum PollResult { case token(OAuthToken), pending, slowDown }

    private func pollOnce(deviceCode: String) async throws -> PollResult {
        let body = "client_id=\(Self.clientID)&device_code=\(deviceCode)&grant_type=\(Self.deviceGrant)"
        let json = try await postForm(body)
        if let accessToken = json["access_token"] as? String {
            return .token(makeToken(accessToken: accessToken, json: json, previousRefresh: nil))
        }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        default: throw OAuthError.http(status: 400, body: (json["error"] as? String) ?? "device flow failed")
        }
    }

    private func postForm(_ body: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let data: Data
        do { (data, _) = try await OAuthHTTP.session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.invalidResponse
        }
        return json
    }

    private func makeToken(accessToken: String, json: [String: Any], previousRefresh: String?) -> OAuthToken {
        let expiresIn = json["expires_in"] as? Double
        let refresh = (json["refresh_token"] as? String) ?? previousRefresh
        return OAuthToken(
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
    }
}
