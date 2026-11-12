import Foundation

/// Mistral provider, supporting three independent auth methods:
///   1. Mistral account (browser sign-in, as the Vibe CLI does): mints an API key that reads the
///      billing API (`/v1/billing/budget`) for the included API and Vibe usage. Any plan.
///   2. Console session cookie (optional): the same quotas scraped from `/subscription`, plus the
///      priced pay-as-you-go overage, which the billing API doesn't expose.
///   3. Admin API key (org spend via the Admin API — Enterprise only).
///
/// When the account and the cookie are both present, the account's Plans win and the cookie only
/// adds what's missing (the overage card). See docs/mistral-billing-api.md and ADR-0007.
struct MistralProvider: UsageProvider {
    let provider = Provider.mistral
    let minimumPollInterval: TimeInterval = 300  // console page is heavy; poll gently

    private let secrets: CredentialStore
    private let adminFetcher = MistralUsageFetcher()
    private let consoleFetcher = MistralConsoleFetcher()
    private let billingFetcher = MistralBillingFetcher()
    private let signInClient = MistralSignInClient()
    private static let adminKeyAccount = "mistral.admin-key"
    private static let consoleSessionAccount = "mistral.console-session"
    private static let apiKeyAccount = "mistral.api-key"

    private static let quotaPlanIDs = [
        "\(Provider.mistral.rawValue).api",
        "\(Provider.mistral.rawValue).api.extra",
        "\(Provider.mistral.rawValue).vibe"
    ]

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    // MARK: - Auth methods

    var authMethods: [AuthMethod] {
        let secrets = self.secrets
        let signInClient = self.signInClient
        return [
            AuthMethod(
                id: "mistral.account",
                provider: .mistral,
                title: "Mistral account",
                instructions: "Sign in in the browser. Tracks your included monthly API and Vibe usage.",
                ownedPlanIDs: Self.quotaPlanIDs,
                isSignedIn: { await secrets.secret(for: Self.apiKeyAccount) != nil },
                signIn: {
                    let process = try await signInClient.start()
                    await Browser.open(process.signInURL)
                    return .browserApproval(
                        url: process.signInURL,
                        instructions: "Approve the sign-in in your browser. This creates a Mistral API key that the widget uses only to read your usage."
                    ) {
                        let key = try await signInClient.waitForKey(process)
                        await secrets.saveSecret(key, for: Self.apiKeyAccount)
                    }
                },
                signOut: { await secrets.clearSecret(for: Self.apiKeyAccount) }
            ),
            AuthMethod(
                id: "mistral.console",
                provider: .mistral,
                title: "Mistral (console session)",
                instructions: "Optional. Adds the pay-as-you-go overage in €, via a console session cookie that expires.",
                ownedPlanIDs: Self.quotaPlanIDs,
                isSignedIn: { await secrets.secret(for: Self.consoleSessionAccount) != nil },
                signIn: {
                    .needsKey(instructions: "Paste the Cookie value from admin.mistral.ai (DevTools → Application → Cookies → copy the ory_session_… cookie as name=value).") { cookie in
                        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { throw OAuthError.invalidResponse }
                        await secrets.saveSecret(trimmed, for: Self.consoleSessionAccount)
                    }
                },
                signOut: { await secrets.clearSecret(for: Self.consoleSessionAccount) }
            ),
            AuthMethod(
                id: "mistral.admin-key",
                provider: .mistral,
                title: "Mistral (Admin API key)",
                instructions: "Track org spend with an Admin API key (Enterprise only).",
                ownedPlanIDs: [Provider.mistral.rawValue],
                isSignedIn: { await secrets.secret(for: Self.adminKeyAccount) != nil },
                signIn: {
                    .needsKey(instructions: "Paste your Mistral Admin API key (admin.mistral.ai → API Keys). Note: the Admin API is Enterprise-only.") { key in
                        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { throw OAuthError.invalidResponse }
                        await secrets.saveSecret(trimmed, for: Self.adminKeyAccount)
                    }
                },
                signOut: { await secrets.clearSecret(for: Self.adminKeyAccount) }
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

        if let key = await secrets.secret(for: Self.apiKeyAccount), !key.isEmpty {
            do {
                plans.append(contentsOf: try await billingFetcher.fetch(apiKey: key).plans)
            } catch {
                failures.append("account: \(error.localizedDescription)")
            }
        }

        if let cookie = await secrets.secret(for: Self.consoleSessionAccount), !cookie.isEmpty {
            do {
                let consolePlans = try await consoleFetcher.fetch(sessionCookie: cookie).plans
                plans = Self.merge(plans, adding: consolePlans)
            } catch {
                failures.append("console: \(error.localizedDescription)")
            }
        }

        if let key = await secrets.secret(for: Self.adminKeyAccount), !key.isEmpty {
            do {
                plans.append(contentsOf: try await adminFetcher.fetch(apiKey: key).plans)
            } catch {
                failures.append("admin: \(error.localizedDescription)")
            }
        }

        guard !plans.isEmpty else {
            if failures.isEmpty { throw ProviderError.notSignedIn }
            throw ProviderError.transport(failures.joined(separator: "; "))
        }
        return ProviderUsage(provider: provider, plans: plans, fetchedAt: Date())
    }

    /// Plans from `extra` whose ID isn't already present (the account's Plans win over the
    /// cookie's; the cookie then only contributes the priced overage card).
    static func merge(_ plans: [Plan], adding extra: [Plan]) -> [Plan] {
        let known = Set(plans.map(\.id))
        return plans + extra.filter { !known.contains($0.id) }
    }
}
