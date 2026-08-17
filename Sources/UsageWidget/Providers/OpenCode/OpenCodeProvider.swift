import Foundation

/// OpenCode provider: a single API key authenticates the `Go` quota plan against
/// `GET /zen/go/v1/usage`.
///
/// CONTEXT.md models OpenCode as one Provider → two Plans (`Go` + `Zen`). Only Go has an
/// API-key endpoint; Zen (spend, prepaid balance) is console-only and deferred to a later phase
/// (see docs/spike-findings.md). The shared credential is stored once, so Zen can reuse it when
/// it lands.
struct OpenCodeProvider: UsageProvider {
    let provider = Provider.openCode
    let minimumPollInterval: TimeInterval = 60

    private let secrets: CredentialStore
    private let goFetcher = OpenCodeGoFetcher()
    private static let keyAccount = "opencode.api-key"

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    func authState() async -> ProviderAuthState {
        await secrets.secret(for: Self.keyAccount) != nil ? .signedIn : .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        let secrets = self.secrets
        let instructions = "Paste your OpenCode API key (opencode.ai → workspace → Keys; format sk-…)."
        return .needsKey(instructions: instructions) { key in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw OAuthError.invalidResponse }
            await secrets.saveSecret(trimmed, for: Self.keyAccount)
        }
    }

    func signOut() async {
        await secrets.clearSecret(for: Self.keyAccount)
    }

    func fetchUsage() async throws -> ProviderUsage {
        guard let key = await secrets.secret(for: Self.keyAccount), !key.isEmpty else {
            throw ProviderError.notSignedIn
        }
        // Zen (spend) is deferred — no API-key endpoint. Return Go only for now.
        return try await goFetcher.fetch(apiKey: key)
    }
}
