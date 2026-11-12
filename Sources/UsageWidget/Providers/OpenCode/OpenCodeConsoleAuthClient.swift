import Foundation

/// OpenCode Console sign-in via the **device flow**, the same login the OpenCode CLI uses
/// (`/console/auth/device/code` → `/console/auth/device/token`). The user approves a short code
/// in the browser. We receive an access + refresh token and pick a workspace from `/api/orgs`.
///
/// Anomaly offers no client registration for third-party apps, so we present OpenCode's own
/// public `opencode-cli` client ID. This is undocumented and may be blocked; see ADR-0006.
struct OpenCodeConsoleAuthClient: Sendable {
    static let clientID = "opencode-cli"
    static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"
    static let server = OpenCodeConsole.server

    struct DeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURIComplete: String
        let expiresIn: Int
        let interval: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }

        /// The approval page. The Console may return it relative to its base path.
        var verificationURL: URL {
            URL(string: verificationURIComplete, relativeTo: URL(string: "\(OpenCodeConsoleAuthClient.server)/"))?
                .absoluteURL ?? URL(string: OpenCodeConsoleAuthClient.server)!
        }
    }

    struct Org: Decodable, Sendable, Equatable {
        let id: String
        let name: String
    }

    /// A signed-in Console session: the token plus the workspace it acts in.
    struct Session: Sendable {
        let token: OAuthToken
        let org: Org?
    }

    enum TokenResult: Sendable {
        case token(OAuthToken, orgID: String?)
        case pending
        case slowDown
        case failed(String)
    }

    // MARK: - Device flow

    func requestDeviceCode() async throws -> DeviceCode {
        let data = try await postJSON(
            path: "/auth/device/code",
            body: ["client_id": Self.clientID, "supports_org_scope": true]
        )
        do {
            return try JSONDecoder().decode(DeviceCode.self, from: data)
        } catch {
            throw OAuthError.invalidResponse
        }
    }

    /// Poll until the user approves, honoring the interval / slow_down, until expiry. Then resolve
    /// the workspace the login chose (or the first by name when it chose none).
    func pollForSession(_ device: DeviceCode) async throws -> Session {
        var delay = max(device.interval, 2)
        var elapsed = 0
        while elapsed < device.expiresIn {
            try await Task.sleep(for: .seconds(delay))
            elapsed += delay
            let data = try await postJSON(path: "/auth/device/token", body: [
                "grant_type": Self.deviceGrant,
                "device_code": device.deviceCode,
                "client_id": Self.clientID
            ], requireOK: false)
            switch Self.parseToken(data, previousRefresh: nil) {
            case .token(let token, let orgID):
                let orgs = try await orgs(accessToken: token.accessToken)
                return Session(token: token, org: Self.pickOrg(orgs, preferredID: orgID))
            case .pending: continue
            case .slowDown: delay += 5
            case .failed(let error): throw OAuthError.http(status: 400, body: error)
            }
        }
        throw OAuthError.timeout
    }

    // MARK: - Refresh

    /// Exchange the refresh token. `invalid_grant` (revoked or expired session) maps to
    /// `.unauthorized` so the caller drops the login and asks the user to sign in again.
    func refresh(_ token: OAuthToken) async throws -> (token: OAuthToken, orgID: String?) {
        guard let refreshToken = token.refreshToken else { throw ProviderError.unauthorized }
        let data = try await postJSON(path: "/auth/device/token", body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ], requireOK: false)
        switch Self.parseToken(data, previousRefresh: refreshToken) {
        case .token(let refreshed, let orgID): return (refreshed, orgID)
        default: throw ProviderError.unauthorized
        }
    }

    // MARK: - Workspaces

    func orgs(accessToken: String) async throws -> [Org] {
        var request = URLRequest(url: URL(string: "\(Self.server)/api/orgs")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(OpenCodeConsole.userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await UsageHTTP.get(request)
        do {
            return try JSONDecoder().decode([Org].self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Pure helpers (exposed for self-checks)

    /// Parse a `/auth/device/token` response: a token (with the workspace the login chose, if
    /// any) or a device-flow error code.
    static func parseToken(_ data: Data, previousRefresh: String?) -> TokenResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("invalid response")
        }
        if let access = json["access_token"] as? String {
            let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
            let token = OAuthToken(
                accessToken: access,
                refreshToken: (json["refresh_token"] as? String) ?? previousRefresh,
                expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
            )
            return .token(token, orgID: json["org_id"] as? String)
        }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case let error?: return .failed(error)
        case nil: return .failed("invalid response")
        }
    }

    /// The workspace the login chose, else the first by name (as the OpenCode CLI does).
    static func pickOrg(_ orgs: [Org], preferredID: String?) -> Org? {
        if let preferredID {
            return orgs.first { $0.id == preferredID } ?? Org(id: preferredID, name: preferredID)
        }
        return orgs.min { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: - HTTP

    private func postJSON(path: String, body: [String: Any], requireOK: Bool = true) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.server)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(OpenCodeConsole.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await OAuthHTTP.session.data(for: request) }
        catch { throw ProviderError.transport(error.localizedDescription) }
        if requireOK, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OAuthError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
