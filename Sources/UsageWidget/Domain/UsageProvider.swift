import Foundation

/// Errors a provider can surface. The engine maps these into per-provider UI states.
enum ProviderError: Error, Sendable, Equatable {
    /// No stored credentials — the card should prompt sign-in.
    case notSignedIn
    /// Token rejected (401). The provider tries one refresh+retry before throwing this.
    case unauthorized
    /// 429. `retryAfter` is honored when the server provides it; otherwise the engine backs off.
    case rateLimited(retryAfter: TimeInterval?)
    /// Network/transport failure (offline, DNS, TLS, timeouts).
    case transport(String)
    /// Response could not be decoded into the expected shape.
    case decoding(String)
    /// An API key/secret was rejected (401/403) — distinct from an expired OAuth token.
    case badCredentials(String)
    /// A local resource can't be read (e.g. Cursor's database) — typically a missing system
    /// permission like Full Disk Access, or the app not being installed.
    case permissionDenied(String)
}

extension ProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in"
        case .unauthorized: "Session expired — sign in again"
        case .rateLimited: "Rate limited — backing off"
        case .transport(let message): "Network error: \(message)"
        case .decoding(let message): "Unexpected response: \(message)"
        case .badCredentials(let message): message
        case .permissionDenied(let message): message
        }
    }
}

/// A single sign-in method a provider can offer when it supports more than one
/// (e.g. Claude: OAuth subscription vs. admin-API-key billing).
struct SignInOption: Sendable {
    let id: String
    let title: String
    let instructions: String
    /// Begin this method's flow, returning the next `SignInContinuation` for the UI to render.
    let start: @Sendable () async throws -> SignInContinuation
}

/// A single text field a sign-in form must collect (label + placeholder + secure toggle).
struct SignInField: Sendable, Identifiable {
    let id: String
    let label: String
    let placeholder: String
    let isSecure: Bool

    init(id: String, label: String, placeholder: String, isSecure: Bool = false) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.isSecure = isSecure
    }
}

/// One selectable option in a discovery-selection step (e.g. a `service.description` the user
/// identifies as Gemini-related in their own billing export).
struct SelectionOption: Sendable, Identifiable {
    /// Stable value submitted back to the provider (e.g. the service description).
    let id: String
    /// What the user sees (usually the same as `id`).
    let label: String
    /// Optional supporting detail (e.g. the cost attributed to this option).
    let detail: String?

    init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

/// How a sign-in flow proceeds after it begins. Different providers need different UX:
/// Codex completes autonomously via a loopback redirect; Claude needs the user to paste a code;
/// Copilot uses the GitHub device flow; Mistral accepts a pasted admin API key.
enum SignInContinuation: Sendable {
    /// Sign-in finished inside `signIn()` (e.g. Codex captured the loopback code).
    case completed
    /// Ask the user to choose between multiple sign-in methods (e.g. Claude).
    case choose(options: [SignInOption])
    /// The browser is showing a code the user must paste back. Call `submit(code)` to finish.
    case needsCode(instructions: String, submit: @Sendable (String) async throws -> Void)
    /// Device flow: show `userCode` for the user to enter at `verificationURL`, then await `poll`
    /// (which resolves when the user authorizes). Used by GitHub Copilot.
    case deviceCode(userCode: String, verificationURL: URL, instructions: String, poll: @Sendable () async throws -> Void)
    /// API-key flow: prompt for a pasted key and call `submit(key)`. Used by Mistral.
    case needsKey(instructions: String, submit: @Sendable (String) async throws -> Void)
    /// Multi-field credential form (e.g. Scaleway's secret key + organization ID). Call
    /// `submit(values)` with the collected values keyed by `SignInField.id`. The submit may
    /// return a follow-up `SignInContinuation` (e.g. Gemini runs a discovery query and then asks
    /// the user to select the relevant services); `nil` finishes the flow.
    case needsFields(title: String, fields: [SignInField], submit: @Sendable ([String: String]) async throws -> SignInContinuation?)
    /// Discovery-selection step: the provider ran a discovery query and needs the user to pick
    /// which options are relevant (e.g. the Gemini-related `service` rows in a billing export).
    /// Call `submit(selectedIDs)` with the chosen `SelectionOption.id`s.
    case needsSelection(title: String, instructions: String, options: [SelectionOption], submit: @Sendable ([String]) async throws -> Void)
    /// A system-permission flow (Cursor needs Full Disk Access): no credential is entered into the
    /// widget. The user grants the permission in System Settings, then taps retry to verify access.
    case needsPermission(
        title: String,
        instructions: String,
        openSettings: (@Sendable () -> Void)?,
        retry: @Sendable () async throws -> Void
    )
}

enum ProviderAuthState: Sendable, Equatable {
    case signedOut
    case signedIn
}

/// A single independently-connectable credential a provider exposes.
///
/// Most providers expose exactly one. OpenCode exposes two (`Go` quota + `Zen` spend); Claude
/// exposes two (subscription OAuth + admin API key). Each method is connected and disconnected on
/// its own — the Accounts panel treats them as separate sign-ins, while the domain model keeps
/// them as two Plans under one Provider.
struct AuthMethod: Identifiable, Sendable {
    /// Stable, unique across all providers (e.g. "opencode.go", "claude.subscription").
    let id: String
    let provider: Provider
    /// What the Accounts panel shows (e.g. "OpenCode Go", "Claude Code (subscription)").
    let title: String
    /// What this method tracks, shown under its title in the Accounts panel.
    let instructions: String
    /// Plan ids this method owns — removed from the store when the method is signed out. Empty
    /// means "every plan of `provider`" (the single-method default).
    let ownedPlanIDs: [String]
    let isSignedIn: @Sendable () async -> Bool
    let signIn: @Sendable () async throws -> SignInContinuation
    let signOut: @Sendable () async -> Void
}

/// The load-bearing seam: every Provider conforms to this protocol.
///
/// Each conformer owns its own authentication and fetcher, and returns a normalized
/// `ProviderUsage`. Adding a provider is one new module with zero changes to the engine
/// (see ADR-0003).
protocol UsageProvider: Sendable {
    /// The `Provider` this fetcher authenticates against.
    var provider: Provider { get }

    /// Hard floor the engine must never poll faster than (protects rate-limited endpoints).
    var minimumPollInterval: TimeInterval { get }

    /// The independently-connectable auth methods, in display order. Defaults to a single method
    /// wrapping `authState`/`signIn`/`signOut` (see the protocol extension).
    var authMethods: [AuthMethod] { get }

    /// Whether credentials are stored and usable.
    func authState() async -> ProviderAuthState

    /// Begin authentication. Returns a `SignInContinuation` describing what the UI must do next.
    func signIn() async throws -> SignInContinuation

    func signOut() async

    /// Fetch the latest usage, normalized into a `ProviderUsage`.
    func fetchUsage() async throws -> ProviderUsage
}

extension UsageProvider {
    /// Default: a single method delegating to the provider's whole-provider `authState`/`signIn`/
    /// `signOut`. Multi-method providers (OpenCode, Claude) override this with one method per
    /// credential.
    var authMethods: [AuthMethod] {
        [AuthMethod(
            id: provider.rawValue,
            provider: provider,
            title: provider.displayName,
            instructions: "Connect \(provider.displayName).",
            ownedPlanIDs: [],
            isSignedIn: { await self.authState() == .signedIn },
            signIn: { try await self.signIn() },
            signOut: { await self.signOut() }
        )]
    }
}
