import Foundation

/// Serializes Keychain access. An actor so concurrent provider refreshes can't race on
/// read-modify-write of the same credentials.
///
/// Holds both OAuth tokens (Codable `OAuthToken` per `Provider`) and opaque secrets
/// (e.g. Mistral's admin API key).
actor CredentialStore {
    private let keychain: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(service: String) {
        self.keychain = KeychainStore(service: service)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private func tokenAccount(_ id: Provider) -> String { "\(id.rawValue).oauth" }

    // MARK: OAuth tokens

    func token(for id: Provider) -> OAuthToken? {
        guard let data = try? keychain.get(account: tokenAccount(id)) else { return nil }
        return try? decoder.decode(OAuthToken.self, from: data)
    }

    func saveToken(_ token: OAuthToken, for id: Provider) {
        guard let data = try? encoder.encode(token) else { return }
        try? keychain.set(data, account: tokenAccount(id))
    }

    func clearToken(for id: Provider) {
        try? keychain.delete(account: tokenAccount(id))
    }

    // MARK: Opaque secrets (API keys)

    func secret(for account: String) -> String? {
        guard let data = try? keychain.get(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveSecret(_ secret: String, for account: String) {
        try? keychain.set(Data(secret.utf8), account: account)
    }

    func clearSecret(for account: String) {
        try? keychain.delete(account: account)
    }
}
