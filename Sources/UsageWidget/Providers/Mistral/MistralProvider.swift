import Foundation

/// Mistral provider: admin API-key auth and monthly-spend fetch. Mistral is a spend Plan —
/// pay-as-you-go with no prepaid balance, so the card shows raw currency (and a % only once a
/// user Budget is set in Phase 4).
struct MistralProvider: UsageProvider {
    let provider = Provider.mistral
    let minimumPollInterval: TimeInterval = 60

    private let secrets: CredentialStore
    private let fetcher = MistralUsageFetcher()
    private static let keyAccount = "mistral.admin-key"

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    func authState() async -> ProviderAuthState {
        await secrets.secret(for: Self.keyAccount) != nil ? .signedIn : .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        let secrets = self.secrets
        let instructions = "Paste your Mistral Admin API key (admin.mistral.ai → API Keys). Note: the Admin API is Enterprise-only."
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
        return try await fetcher.fetch(apiKey: key)
    }
}
