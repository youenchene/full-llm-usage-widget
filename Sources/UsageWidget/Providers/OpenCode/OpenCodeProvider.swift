import Foundation

/// OpenCode provider: one Provider → two Plans (CONTEXT.md):
///   1. `OpenCode Go subscription` (quota), from `GET /zen/go/v1/usage`.
///   2. `OpenCode Console` (spend; formerly "Zen"), from the Console budgets API plus, optionally,
///      the balance scraped from the billing page.
///
/// Three independent `AuthMethod`s feed them:
///   - **Console account** (device login, refreshing tokens): Go + Console spend/budget.
///   - **API key** (`oc_sk_…` personal key + workspace ID): the same data, no login.
///   - **Balance cookie** (optional): the only source of the credit `Balance`.
/// When both a login and a key are present, the login wins.
struct OpenCodeProvider: UsageProvider {
    let provider = Provider.openCode
    let minimumPollInterval: TimeInterval = 300  // billing data moves slowly

    private let secrets: CredentialStore
    private let auth = OpenCodeConsoleAuthClient()
    private let goFetcher = OpenCodeGoFetcher()
    private let budgetsFetcher = OpenCodeBudgetsFetcher()
    private let balanceFetcher = OpenCodeConsoleBalanceFetcher()

    /// Device-login workspace (the login's token itself is stored via `token(for: .openCode)`).
    private static let loginWorkspaceAccount = "opencode.console.org-id"
    /// Personal API key. The account name predates the Console rename; kept so stored keys survive.
    private static let keyAccount = "opencode.api-key"
    private static let keyWorkspaceAccount = "opencode.api-key.org-id"
    /// Balance-cookie credentials (account names kept from the Zen era).
    private static let cookieWorkspaceAccount = "opencode.zen.workspace-id"
    private static let cookieAccount = "opencode.zen.cookie"

    private static let bothPlans = [OpenCodeGoFetcher.planID, OpenCodeConsoleBalanceFetcher.planID]

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    // MARK: - Auth methods

    var authMethods: [AuthMethod] { [loginMethod, keyMethod, cookieMethod] }

    private var loginMethod: AuthMethod {
        AuthMethod(
            id: "opencode.console",
            provider: .openCode,
            title: "OpenCode Console account",
            instructions: "Sign in in the browser. Tracks Go subscription limits and Console spend against your budget.",
            ownedPlanIDs: Self.bothPlans,
            isSignedIn: { await secrets.token(for: .openCode) != nil },
            signIn: {
                let device = try await auth.requestDeviceCode()
                let url = device.verificationURL
                await Browser.open(url)
                return .deviceCode(
                    userCode: device.userCode,
                    verificationURL: url,
                    instructions: "Approve this code in the OpenCode Console to connect your account."
                ) {
                    let session = try await auth.pollForSession(device)
                    await secrets.saveToken(session.token, for: .openCode)
                    if let org = session.org {
                        await secrets.saveSecret(org.id, for: Self.loginWorkspaceAccount)
                    } else {
                        await secrets.clearSecret(for: Self.loginWorkspaceAccount)
                    }
                }
            },
            signOut: {
                await secrets.clearToken(for: .openCode)
                await secrets.clearSecret(for: Self.loginWorkspaceAccount)
            }
        )
    }

    private var keyMethod: AuthMethod {
        AuthMethod(
            id: "opencode.api-key",
            provider: .openCode,
            title: "OpenCode API key",
            instructions: "A personal API key. Tracks Go subscription limits, plus Console spend when a workspace ID is set.",
            ownedPlanIDs: Self.bothPlans,
            isSignedIn: { await secrets.secret(for: Self.keyAccount) != nil },
            signIn: {
                .needsFields(
                    title: "Create a personal key in the OpenCode Console (Account › Personal API keys, oc_sk_…). For Console spend, give it Read only, or Restricted with Usage and Budgets set to Read. The workspace ID is the wrk_… in Console URLs.",
                    fields: [
                        SignInField(id: "key", label: "API key", placeholder: "oc_sk_…", isSecure: true),
                        SignInField(id: "workspace", label: "Workspace ID (optional, for Console spend)", placeholder: "wrk_…")
                    ]
                ) { values in
                    let key = values["key"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let workspace = values["workspace"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !key.isEmpty else { throw OAuthError.invalidResponse }
                    await secrets.saveSecret(key, for: Self.keyAccount)
                    if workspace.isEmpty {
                        await secrets.clearSecret(for: Self.keyWorkspaceAccount)
                    } else {
                        await secrets.saveSecret(workspace, for: Self.keyWorkspaceAccount)
                    }
                    return nil
                }
            },
            signOut: {
                await secrets.clearSecret(for: Self.keyAccount)
                await secrets.clearSecret(for: Self.keyWorkspaceAccount)
            }
        )
    }

    private var cookieMethod: AuthMethod {
        AuthMethod(
            id: "opencode.zen",
            provider: .openCode,
            title: "OpenCode Console balance (cookie)",
            instructions: "Optional. Adds your remaining credit balance, which the Console API doesn't expose.",
            ownedPlanIDs: [OpenCodeConsoleBalanceFetcher.planID],
            isSignedIn: {
                let hasWorkspace = await secrets.secret(for: Self.cookieWorkspaceAccount) != nil
                let hasCookie = await secrets.secret(for: Self.cookieAccount) != nil
                return hasWorkspace && hasCookie
            },
            signIn: {
                .needsFields(
                    title: "Copy the `auth` cookie (DevTools → Application → Cookies → opencode.ai → auth; it is httpOnly) and the workspace ID (the wrk_… in Console URLs). The cookie expires; paste a new one when it does.",
                    fields: [
                        SignInField(id: "workspace", label: "Workspace ID", placeholder: "wrk_…"),
                        SignInField(id: "cookie", label: "Auth cookie", placeholder: "Fe26.2**…", isSecure: true)
                    ]
                ) { values in
                    let workspace = values["workspace"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let cookie = values["cookie"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !workspace.isEmpty, !cookie.isEmpty else { throw OAuthError.invalidResponse }
                    await secrets.saveSecret(workspace, for: Self.cookieWorkspaceAccount)
                    await secrets.saveSecret(cookie, for: Self.cookieAccount)
                    return nil
                }
            },
            signOut: {
                await secrets.clearSecret(for: Self.cookieWorkspaceAccount)
                await secrets.clearSecret(for: Self.cookieAccount)
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

    /// Fetch whichever Plans the stored credentials can reach, best-effort per source. If nothing
    /// yields a plan, throw; otherwise return what succeeded (the engine keeps last-good values for
    /// any Plan that failed).
    func fetchUsage() async throws -> ProviderUsage {
        var plans: [Plan] = []
        var failures: [String] = []
        var budgets: [ConsoleBudget]?

        if let bearer = await bearerSource() {
            do {
                if let go = try await bearer.run({ try await goFetcher.fetch(credential: $0) }) {
                    plans.append(go)
                }
            } catch {
                failures.append("Go: \(error.localizedDescription)")
            }
            if bearer.hasWorkspace {
                do {
                    budgets = try await bearer.run { try await budgetsFetcher.fetch(credential: $0) }
                } catch {
                    failures.append("Console: \(error.localizedDescription)")
                }
            }
        }

        var billing: ConsoleBilling?
        if let workspace = await secrets.secret(for: Self.cookieWorkspaceAccount), !workspace.isEmpty,
           let cookie = await secrets.secret(for: Self.cookieAccount), !cookie.isEmpty {
            do {
                billing = try await balanceFetcher.fetch(cookie: cookie, workspaceID: workspace)
            } catch {
                failures.append("Console balance: \(error.localizedDescription)")
            }
        }

        if let budgets {
            plans.append(OpenCodeBudgetsFetcher.makePlan(budgets: budgets, balance: billing?.balance))
        } else if let billing {
            plans.append(billing.makePlan())
        }

        guard !plans.isEmpty else {
            if !failures.isEmpty { throw ProviderError.transport(failures.joined(separator: "; ")) }
            if await authState() == .signedOut { throw ProviderError.notSignedIn }
            throw ProviderError.badCredentials(
                "No OpenCode Go subscription in this workspace, and no Console budgets readable. Add a workspace ID to the API key, or check its permissions."
            )
        }
        return ProviderUsage(provider: provider, plans: plans, fetchedAt: Date())
    }

    // MARK: - Bearer credentials

    /// The bearer credential to use: the Console login if present, else the API key.
    private func bearerSource() async -> BearerSource? {
        if await secrets.token(for: .openCode) != nil {
            let workspace = await secrets.secret(for: Self.loginWorkspaceAccount)
            return BearerSource(kind: .login(workspace: workspace), secrets: secrets, auth: auth)
        }
        if let key = await secrets.secret(for: Self.keyAccount), !key.isEmpty {
            var workspace = await secrets.secret(for: Self.keyWorkspaceAccount)
            if workspace == nil {
                workspace = await secrets.secret(for: Self.cookieWorkspaceAccount)
            }
            return BearerSource(kind: .key(key, workspace: workspace), secrets: secrets, auth: auth)
        }
        return nil
    }

    /// Runs a Console request with a bearer credential, refreshing a login token once on expiry
    /// or a 401, and turning a rejected API key into an actionable message.
    fileprivate struct BearerSource: Sendable {
        enum Kind: Sendable {
            case login(workspace: String?)
            case key(String, workspace: String?)
        }
        let kind: Kind
        let secrets: CredentialStore
        let auth: OpenCodeConsoleAuthClient

        var hasWorkspace: Bool {
            switch kind {
            case .login(let workspace), .key(_, let workspace): return !(workspace ?? "").isEmpty
            }
        }

        func run<T: Sendable>(_ body: @Sendable (OpenCodeCredential) async throws -> T) async throws -> T {
            switch kind {
            case .key(let key, let workspace):
                do {
                    return try await body(OpenCodeCredential(bearer: key, workspaceID: workspace))
                } catch ProviderError.unauthorized {
                    throw ProviderError.badCredentials(
                        "OpenCode rejected the API key (revoked or expired?). Create a personal key under Account › Personal API keys (oc_sk_…)."
                    )
                }
            case .login(let workspace):
                guard var token = await secrets.token(for: .openCode) else { throw ProviderError.notSignedIn }
                if token.needsRefresh() {
                    token = try await refreshAndStore(token)
                }
                do {
                    return try await body(OpenCodeCredential(bearer: token.accessToken, workspaceID: workspace))
                } catch ProviderError.unauthorized {
                    let refreshed = try await refreshAndStore(token)
                    return try await body(OpenCodeCredential(bearer: refreshed.accessToken, workspaceID: workspace))
                }
            }
        }

        /// Refresh and persist the login token. A refused refresh means the Console session was
        /// revoked or expired: drop the login so the Accounts panel asks to sign in again.
        private func refreshAndStore(_ token: OAuthToken) async throws -> OAuthToken {
            // Another fetch may already have rotated the refresh token; use the stored one if newer.
            if let stored = await secrets.token(for: .openCode),
               stored.accessToken != token.accessToken, !stored.needsRefresh() {
                return stored
            }
            do {
                let (refreshed, _) = try await auth.refresh(token)
                await secrets.saveToken(refreshed, for: .openCode)
                return refreshed
            } catch ProviderError.unauthorized {
                await secrets.clearToken(for: .openCode)
                throw ProviderError.unauthorized
            }
        }
    }
}
