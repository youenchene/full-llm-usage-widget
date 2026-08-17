import Foundation

/// Codex provider: loopback OAuth sign-in (127.0.0.1:1455), token refresh, and usage fetch.
actor CodexProvider: UsageProvider {
    nonisolated let provider = Provider.codex
    nonisolated let minimumPollInterval: TimeInterval = 60

    private let tokens: CredentialStore
    private let oauth = CodexOAuthClient()
    private let fetcher = CodexUsageFetcher()

    init(tokens: CredentialStore) {
        self.tokens = tokens
    }

    func authState() async -> ProviderAuthState {
        await tokens.token(for: provider) != nil ? .signedIn : .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        let pkce = PKCE.generate()
        let server = LoopbackOAuthServer(port: CodexOAuthClient.loopbackPort)
        let url = oauth.makeAuthorizeURL(pkce: pkce)
        await Browser.open(url)

        let result: LoopbackResult
        do {
            result = try await server.waitForCallback()
        } catch {
            server.stop()
            throw error
        }
        guard result.state == pkce.state else { throw OAuthError.stateMismatch }

        let token = try await oauth.exchange(code: result.code, pkce: pkce)
        await tokens.saveToken(token, for: provider)
        return .completed
    }

    func signOut() async {
        await tokens.clearToken(for: provider)
    }

    func fetchUsage() async throws -> ProviderUsage {
        guard var token = await tokens.token(for: provider) else { throw ProviderError.notSignedIn }
        if token.needsRefresh() {
            token = try await refreshAndStore(token)
        }
        do {
            return try await fetcher.fetch(accessToken: token.accessToken, accountId: token.accountId, planFallback: token.planType)
        } catch ProviderError.unauthorized {
            let refreshed = try await refreshAndStore(token)
            return try await fetcher.fetch(accessToken: refreshed.accessToken, accountId: refreshed.accountId, planFallback: refreshed.planType)
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
