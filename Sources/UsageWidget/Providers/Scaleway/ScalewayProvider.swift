import Foundation

/// Scaleway provider: a secret key (sent as `X-Auth-Token`) plus an organization ID, querying the
/// Billing v2beta1 consumptions endpoint for monthly "Generative APIs" (inference) spend.
///
/// Scaleway is a spend Plan — pay-as-you-go with no prepaid balance, so the card shows raw
/// currency (and a % only once a user Budget is set in Phase 4).
struct ScalewayProvider: UsageProvider {
    let provider = Provider.scaleway
    let minimumPollInterval: TimeInterval = 300  // monthly billing data moves slowly

    private let secrets: CredentialStore
    private let fetcher = ScalewayUsageFetcher()
    private static let keyAccount = "scaleway.secret-key"
    private static let orgAccount = "scaleway.organization-id"

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    func authState() async -> ProviderAuthState {
        let hasKey = await secrets.secret(for: Self.keyAccount) != nil
        let hasOrg = await secrets.secret(for: Self.orgAccount) != nil
        return (hasKey && hasOrg) ? .signedIn : .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        let secrets = self.secrets
        let fields = [
            SignInField(id: "secret", label: "Secret key", placeholder: "SCW…", isSecure: true),
            SignInField(id: "organization_id", label: "Organization ID", placeholder: "UUID")
        ]
        return .needsFields(
            title: "Connect Scaleway. The secret key needs BillingReadOnly scope; the organization ID is required to query consumption.",
            fields: fields
        ) { values in
            let key = values["secret"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let org = values["organization_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, !org.isEmpty else { throw OAuthError.invalidResponse }
            await secrets.saveSecret(key, for: Self.keyAccount)
            await secrets.saveSecret(org, for: Self.orgAccount)
            return nil
        }
    }

    func signOut() async {
        await secrets.clearSecret(for: Self.keyAccount)
        await secrets.clearSecret(for: Self.orgAccount)
    }

    func fetchUsage() async throws -> ProviderUsage {
        guard let key = await secrets.secret(for: Self.keyAccount), !key.isEmpty else {
            throw ProviderError.notSignedIn
        }
        guard let org = await secrets.secret(for: Self.orgAccount), !org.isEmpty else {
            throw ProviderError.notSignedIn
        }
        return try await fetcher.fetch(secretKey: key, organizationId: org)
    }
}
