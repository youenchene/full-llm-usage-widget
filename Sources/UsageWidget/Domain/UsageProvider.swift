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
    /// `submit(values)` with the collected values keyed by `SignInField.id`.
    case needsFields(title: String, fields: [SignInField], submit: @Sendable ([String: String]) async throws -> Void)
}

enum ProviderAuthState: Sendable, Equatable {
    case signedOut
    case signedIn
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

    /// Whether credentials are stored and usable.
    func authState() async -> ProviderAuthState

    /// Begin authentication. Returns a `SignInContinuation` describing what the UI must do next.
    func signIn() async throws -> SignInContinuation

    func signOut() async

    /// Fetch the latest usage, normalized into a `ProviderUsage`.
    func fetchUsage() async throws -> ProviderUsage
}
