import Foundation

/// Mistral provider, supporting two independent auth methods:
///   1. Admin API key (org spend via the Admin API — Enterprise only).
///   2. Console session cookie (included monthly usage quota via the `/subscription` page — any
///      plan; see docs/mistral-console-scrape.md).
///
/// Either or both may be present, producing up to two `Plan`s. The admin path yields a `spend`
/// plan (no ceiling); the console path yields a `quota` plan (the € monthly included usage resets
/// on a fixed window).
struct MistralProvider: UsageProvider {
    let provider = Provider.mistral
    let minimumPollInterval: TimeInterval = 300  // console page is heavy; poll gently

    private let secrets: CredentialStore
    private let adminFetcher = MistralUsageFetcher()
    private let consoleFetcher = MistralConsoleFetcher()
    private static let adminKeyAccount = "mistral.admin-key"
    private static let consoleSessionAccount = "mistral.console-session"

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    // MARK: - Auth methods

    var authMethods: [AuthMethod] {
        let secrets = self.secrets
        return [
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
            ),
            AuthMethod(
                id: "mistral.console",
                provider: .mistral,
                title: "Mistral (console session)",
                instructions: "Track your included monthly usage via a console session cookie.",
                ownedPlanIDs: ["\(Provider.mistral.rawValue).api"],
                isSignedIn: { await secrets.secret(for: Self.consoleSessionAccount) != nil },
                signIn: {
                    .needsKey(instructions: "Paste the Cookie value from admin.mistral.ai (DevTools → Application → Cookies → copy the ory_session_… cookie as name=value).") { cookie in
                        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { throw OAuthError.invalidResponse }
                        await secrets.saveSecret(trimmed, for: Self.consoleSessionAccount)
                    }
                },
                signOut: { await secrets.clearSecret(for: Self.consoleSessionAccount) }
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

        if let key = await secrets.secret(for: Self.adminKeyAccount), !key.isEmpty {
            do {
                plans.append(contentsOf: try await adminFetcher.fetch(apiKey: key).plans)
            } catch {
                failures.append("admin: \(error.localizedDescription)")
            }
        }

        if let cookie = await secrets.secret(for: Self.consoleSessionAccount), !cookie.isEmpty {
            do {
                plans.append(contentsOf: try await consoleFetcher.fetch(sessionCookie: cookie).plans)
            } catch {
                failures.append("console: \(error.localizedDescription)")
            }
        }

        guard !plans.isEmpty else {
            if failures.isEmpty { throw ProviderError.notSignedIn }
            throw ProviderError.transport(failures.joined(separator: "; "))
        }
        return ProviderUsage(provider: provider, plans: plans, fetchedAt: Date())
    }
}
