import Foundation

/// GitHub Copilot provider: device-flow OAuth sign-in, token refresh, and monthly-quota fetch.
actor CopilotProvider: UsageProvider {
    nonisolated let provider = Provider.copilot
    nonisolated let minimumPollInterval: TimeInterval = 120  // monthly quota moves slowly

    private let tokens: CredentialStore
    private let oauth = CopilotOAuthClient()
    private let fetcher = CopilotUsageFetcher()

    init(tokens: CredentialStore) {
        self.tokens = tokens
    }

    func authState() async -> ProviderAuthState {
        await tokens.token(for: provider) != nil ? .signedIn : .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        let device = try await oauth.requestDeviceCode()
        let url = URL(string: device.verificationURI) ?? URL(string: "https://github.com/login/device")!
        await Browser.open(url)

        let oauth = self.oauth
        let tokens = self.tokens
        let id = self.provider
        return .deviceCode(
            userCode: device.userCode,
            verificationURL: url,
            instructions: "Enter this code at github.com/login/device to connect Copilot."
        ) {
            let token = try await oauth.pollForToken(deviceCode: device.deviceCode, interval: device.interval, expiresIn: device.expiresIn)
            await tokens.saveToken(token, for: id)
        }
    }

    func signOut() async {
        await tokens.clearToken(for: provider)
    }

    func fetchUsage() async throws -> ProviderUsage {
        guard var token = await tokens.token(for: provider) else { throw ProviderError.notSignedIn }
        if token.needsRefresh(), token.refreshToken != nil {
            token = (try? await refreshAndStore(token)) ?? token
        }
        do {
            return try await fetcher.fetch(accessToken: token.accessToken)
        } catch ProviderError.unauthorized {
            if token.refreshToken != nil {
                let refreshed = try await refreshAndStore(token)
                return try await fetcher.fetch(accessToken: refreshed.accessToken)
            }
            await tokens.clearToken(for: provider)  // non-expiring token was revoked → require re-auth
            throw ProviderError.unauthorized
        }
    }

    private func refreshAndStore(_ token: OAuthToken) async throws -> OAuthToken {
        do {
            let refreshed = try await oauth.refresh(token)
            await tokens.saveToken(refreshed, for: provider)
            return refreshed
        } catch {
            await tokens.clearToken(for: provider)
            throw ProviderError.unauthorized
        }
    }
}
