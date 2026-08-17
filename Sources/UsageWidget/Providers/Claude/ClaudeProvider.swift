import Foundation

/// Claude provider, supporting two independent auth methods:
///   1. Claude Code OAuth (subscription quota: 5h + weekly).
///   2. Admin API key (billing spend via the Cost Report API).
///
/// Either or both credentials may be present, producing up to two `Plan`s. Each credential is an
/// independent `AuthMethod`, so the Accounts panel connects/disconnects them separately.
actor ClaudeProvider: UsageProvider {
    nonisolated let provider = Provider.claude
    nonisolated let minimumPollInterval: TimeInterval = 300  // Anthropic rate-limits hard

    private let tokens: CredentialStore
    private let oauth = ClaudeOAuthClient()
    private let usageFetcher = ClaudeUsageFetcher()
    private let profile = ClaudeProfileFetcher()
    private let billingFetcher = ClaudeBillingFetcher()
    private static let adminKeyAccount = "claude.admin-key"

    init(tokens: CredentialStore) {
        self.tokens = tokens
    }

    // MARK: - Auth methods

    nonisolated var authMethods: [AuthMethod] {
        let oauth = self.oauth
        let tokens = self.tokens
        let providerID = self.provider
        return [
            AuthMethod(
                id: "claude.subscription",
                provider: .claude,
                title: "Claude Code (subscription)",
                instructions: "Track the 5-hour and weekly subscription quotas.",
                ownedPlanIDs: [Provider.claude.rawValue],
                isSignedIn: { await tokens.token(for: providerID) != nil },
                signIn: {
                    let pkce = PKCE.generate()
                    let url = oauth.makeAuthorizeURL(pkce: pkce)
                    await Browser.open(url)
                    return .needsCode(instructions: "Approve access in your browser, then paste the code it shows (looks like \"abc123#xyz\").") { pastedCode in
                        let token = try await oauth.exchange(pastedCode: pastedCode, pkce: pkce)
                        await tokens.saveToken(token, for: providerID)
                    }
                },
                signOut: { await tokens.clearToken(for: providerID) }
            ),
            AuthMethod(
                id: "claude.api-key",
                provider: .claude,
                title: "Claude API (billing)",
                instructions: "Track your API spend with an Admin API key.",
                ownedPlanIDs: ["claude.api"],
                isSignedIn: { await tokens.secret(for: Self.adminKeyAccount) != nil },
                signIn: {
                    .needsKey(instructions: "Paste your Claude Admin API key (platform.claude.com → Settings → Admin keys).") { key in
                        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { throw OAuthError.invalidResponse }
                        await tokens.saveSecret(trimmed, for: Self.adminKeyAccount)
                    }
                },
                signOut: { await tokens.clearSecret(for: Self.adminKeyAccount) }
            )
        ]
    }

    // MARK: - Whole-provider operations (derived from the methods)

    func authState() async -> ProviderAuthState {
        for method in authMethods where await method.isSignedIn() { return .signedIn }
        return .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        .choose(options: authMethods.map { method in
            SignInOption(id: method.id, title: method.title, instructions: method.instructions) {
                try await method.signIn()
            }
        })
    }

    func signOut() async {
        for method in authMethods { await method.signOut() }
    }

    /// Fetch whichever methods have credentials, best-effort per method. If no method yields a
    /// plan, throw; otherwise return the plans that succeeded (the engine preserves last-good
    /// values for any method that failed).
    func fetchUsage() async throws -> ProviderUsage {
        var plans: [Plan] = []
        var failures: [String] = []

        if let token = await tokens.token(for: provider) {
            do {
                var current = token
                if current.needsRefresh() {
                    current = try await refreshAndStore(current)
                }
                current = await ensurePlan(current)
                let usage = try await usageFetcher.fetch(accessToken: current.accessToken, plan: current.planType)
                plans.append(contentsOf: usage.plans)
            } catch {
                failures.append("subscription: \(error.localizedDescription)")
            }
        }

        if let key = await tokens.secret(for: Self.adminKeyAccount), !key.isEmpty {
            do {
                let usage = try await billingFetcher.fetch(apiKey: key)
                plans.append(contentsOf: usage.plans)
            } catch {
                failures.append("billing: \(error.localizedDescription)")
            }
        }

        guard !plans.isEmpty else {
            if failures.isEmpty { throw ProviderError.notSignedIn }
            throw ProviderError.transport(failures.joined(separator: "; "))
        }
        return ProviderUsage(provider: provider, plans: plans, fetchedAt: Date())
    }

    /// The usage endpoint carries no plan, so fetch the profile once and cache it on the token.
    /// Best-effort: a failure just leaves the badge off — usage still loads.
    private func ensurePlan(_ token: OAuthToken) async -> OAuthToken {
        guard token.planType == nil else { return token }
        guard let raw = try? await profile.fetchRawPlan(accessToken: token.accessToken) else {
            return token
        }
        var updated = token
        updated.planType = raw
        await tokens.saveToken(updated, for: provider)
        return updated
    }

    private func refreshAndStore(_ token: OAuthToken) async throws -> OAuthToken {
        do {
            var refreshed = try await oauth.refresh(token)
            refreshed.planType = refreshed.planType ?? token.planType   // keep the cached plan
            await tokens.saveToken(refreshed, for: provider)
            return refreshed
        } catch {
            await tokens.clearToken(for: provider)
            throw ProviderError.unauthorized
        }
    }
}
