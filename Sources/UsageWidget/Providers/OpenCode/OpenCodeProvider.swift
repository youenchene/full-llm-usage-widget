import Foundation

/// OpenCode provider: one Provider → two Plans (CONTEXT.md), each with its own credential:
///   1. `Go` (quota): a workspace API key against `GET /zen/go/v1/usage`.
///   2. `Zen` (spend): a console session cookie + workspace ID, scraping the billing page.
///
/// Either or both credentials may be present, producing up to two `Plan`s. Each credential is an
/// independent `AuthMethod`, so the Accounts panel connects/disconnects Go and Zen separately.
struct OpenCodeProvider: UsageProvider {
    let provider = Provider.openCode
    let minimumPollInterval: TimeInterval = 300  // billing data moves slowly

    private let secrets: CredentialStore
    private let goFetcher = OpenCodeGoFetcher()
    private let zenFetcher = OpenCodeZenFetcher()
    private static let keyAccount = "opencode.api-key"
    private static let zenWorkspaceAccount = "opencode.zen.workspace-id"
    private static let zenCookieAccount = "opencode.zen.cookie"

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    // MARK: - Auth methods

    var authMethods: [AuthMethod] { [goMethod, zenMethod] }

    private var goMethod: AuthMethod {
        AuthMethod(
            id: "opencode.go",
            provider: .openCode,
            title: "OpenCode Go",
            instructions: "Track the rolling 5-hour, weekly, and monthly quota windows.",
            ownedPlanIDs: ["opencode.go"],
            isSignedIn: { await secrets.secret(for: Self.keyAccount) != nil },
            signIn: {
                .needsKey(instructions: "Paste your OpenCode API key (opencode.ai → workspace → Keys; sk-…).") { key in
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw OAuthError.invalidResponse }
                    await secrets.saveSecret(trimmed, for: Self.keyAccount)
                }
            },
            signOut: { await secrets.clearSecret(for: Self.keyAccount) }
        )
    }

    private var zenMethod: AuthMethod {
        AuthMethod(
            id: "opencode.zen",
            provider: .openCode,
            title: "OpenCode Zen",
            instructions: "Track dollars spent this month and your remaining balance.",
            ownedPlanIDs: ["opencode.zen"],
            isSignedIn: {
                let hasWorkspace = await secrets.secret(for: Self.zenWorkspaceAccount) != nil
                let hasCookie = await secrets.secret(for: Self.zenCookieAccount) != nil
                return hasWorkspace && hasCookie
            },
            signIn: {
                .needsFields(
                    title: "Connect OpenCode Zen. Copy the `auth` cookie (DevTools → Application → Cookies → opencode.ai → auth — it is httpOnly), and find the workspace ID (the wrk_… in the billing URL).",
                    fields: [
                        SignInField(id: "workspace", label: "Workspace ID", placeholder: "wrk_…"),
                        SignInField(id: "cookie", label: "Auth cookie", placeholder: "Fe26.2**…", isSecure: true)
                    ]
                ) { values in
                    let workspace = values["workspace"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let cookie = values["cookie"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !workspace.isEmpty, !cookie.isEmpty else { throw OAuthError.invalidResponse }
                    await secrets.saveSecret(workspace, for: Self.zenWorkspaceAccount)
                    await secrets.saveSecret(cookie, for: Self.zenCookieAccount)
                }
            },
            signOut: {
                await secrets.clearSecret(for: Self.zenWorkspaceAccount)
                await secrets.clearSecret(for: Self.zenCookieAccount)
            }
        )
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

    // MARK: - Usage

    /// Fetch whichever Plans have credentials, best-effort per Plan. If no method yields a plan,
    /// throw; otherwise return the plans that succeeded (the engine preserves last-good values for
    /// any Plan that failed).
    func fetchUsage() async throws -> ProviderUsage {
        var plans: [Plan] = []
        var failures: [String] = []

        if let key = await secrets.secret(for: Self.keyAccount), !key.isEmpty {
            do {
                let usage = try await goFetcher.fetch(apiKey: key)
                plans.append(contentsOf: usage.plans)
            } catch {
                failures.append("go: \(error.localizedDescription)")
            }
        }

        let workspace = await secrets.secret(for: Self.zenWorkspaceAccount)
        let cookie = await secrets.secret(for: Self.zenCookieAccount)
        if let workspace, !workspace.isEmpty, let cookie, !cookie.isEmpty {
            do {
                let usage = try await zenFetcher.fetch(cookie: cookie, workspaceID: workspace)
                plans.append(contentsOf: usage.plans)
            } catch {
                failures.append("zen: \(error.localizedDescription)")
            }
        }

        guard !plans.isEmpty else {
            if failures.isEmpty { throw ProviderError.notSignedIn }
            throw ProviderError.transport(failures.joined(separator: "; "))
        }
        return ProviderUsage(provider: provider, plans: plans, fetchedAt: Date())
    }
}
