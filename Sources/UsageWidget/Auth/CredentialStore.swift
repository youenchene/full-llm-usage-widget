import Foundation

/// Serializes Keychain access and stores every credential in a single Keychain item.
///
/// The public API is unchanged: callers read/write named tokens and secrets. Internally all
/// credentials live in one `kSecClassGenericPassword` item (one JSON blob under one account), so
/// macOS shows at most one "Always Allow" authorization instead of one per provider. Secrets stay
/// in the Keychain only — never on disk in plaintext (see ADR-0003).
///
/// An actor so concurrent provider refreshes can't race on read-modify-write of the blob.
actor CredentialStore {
    /// The on-disk shape of the single Keychain item.
    private struct Blob: Codable {
        var tokens: [String: OAuthToken] = [:]
        var secrets: [String: String] = [:]
    }

    /// Single Keychain account under which the whole blob is persisted.
    private static let account = "credentials"

    /// Legacy per-provider accounts, read once to migrate into the consolidated blob.
    private static let legacyTokenAccounts = Provider.allCases.map { "\($0.rawValue).oauth" }
    private static let legacySecretAccounts = [
        "claude.admin-key",
        "scaleway.secret-key",
        "scaleway.organization-id",
        "opencode.api-key",
        "mistral.admin-key",
    ]

    private let keychain: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var blob: Blob

    init(service: String) {
        let keychain = KeychainStore(service: service)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        self.keychain = keychain
        self.encoder = encoder
        self.decoder = decoder

        if let data = try? keychain.get(account: Self.account),
           let loaded = try? decoder.decode(Blob.self, from: data) {
            self.blob = loaded
        } else {
            // First run: fold any legacy per-provider items into the single blob. Persist before
            // deleting legacy items so a failed write never loses credentials.
            let migrated = Self.migrateLegacy(keychain: keychain, decoder: decoder)
            if let data = try? encoder.encode(migrated) {
                do {
                    try keychain.set(data, account: Self.account)
                    Self.deleteLegacy(keychain: keychain)
                } catch {
                    // Keep legacy items as the source of truth; retry migration next launch.
                }
            }
            self.blob = migrated
        }
    }

    /// Reads every legacy per-provider item into a fresh blob (does not delete anything).
    private static func migrateLegacy(keychain: KeychainStore, decoder: JSONDecoder) -> Blob {
        var blob = Blob()
        for account in legacyTokenAccounts {
            guard let data = try? keychain.get(account: account),
                  let token = try? decoder.decode(OAuthToken.self, from: data) else { continue }
            blob.tokens[account] = token
        }
        for account in legacySecretAccounts {
            guard let data = try? keychain.get(account: account),
                  let secret = String(data: data, encoding: .utf8) else { continue }
            blob.secrets[account] = secret
        }
        return blob
    }

    /// Removes legacy items after the consolidated blob has been written successfully.
    private static func deleteLegacy(keychain: KeychainStore) {
        for account in legacyTokenAccounts + legacySecretAccounts {
            try? keychain.delete(account: account)
        }
    }

    private func tokenAccount(_ id: Provider) -> String { "\(id.rawValue).oauth" }

    // MARK: OAuth tokens

    func token(for id: Provider) -> OAuthToken? {
        blob.tokens[tokenAccount(id)]
    }

    func saveToken(_ token: OAuthToken, for id: Provider) {
        blob.tokens[tokenAccount(id)] = token
        flush()
    }

    func clearToken(for id: Provider) {
        blob.tokens[tokenAccount(id)] = nil
        flush()
    }

    // MARK: Opaque secrets (API keys)

    func secret(for account: String) -> String? {
        blob.secrets[account]
    }

    func saveSecret(_ secret: String, for account: String) {
        blob.secrets[account] = secret
        flush()
    }

    func clearSecret(for account: String) {
        blob.secrets[account] = nil
        flush()
    }

    private func flush() {
        guard let data = try? encoder.encode(blob) else { return }
        try? keychain.set(data, account: Self.account)
    }
}
