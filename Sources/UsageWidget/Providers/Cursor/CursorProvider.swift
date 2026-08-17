import Foundation

/// Cursor provider: reads Cursor's own auth token from its local `state.vscdb` (Full Disk Access
/// required — opt-in, never requested implicitly) and queries Cursor's usage endpoints.
///
/// Cursor is a quota Plan — a monthly "fast requests" limit (legacy) or, for newer accounts, a
/// monthly credit used as a percentage. There is no credential to type into the widget: Cursor's
/// token is the credential, and "connect" means the user grants this app Full Disk Access in
/// System Settings (see `docs/cursor-full-disk-access.md`).
struct CursorProvider: UsageProvider {
    let provider = Provider.cursor
    let minimumPollInterval: TimeInterval = 300  // monthly quota; be gentle on the endpoints

    private let secrets: CredentialStore
    private let fetcher = CursorUsageFetcher()
    private static let connectedAccount = "cursor.connected"

    init(secrets: CredentialStore) {
        self.secrets = secrets
    }

    func authState() async -> ProviderAuthState {
        await secrets.secret(for: Self.connectedAccount) != nil ? .signedIn : .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        let secrets = self.secrets
        return .needsPermission(
            title: "Full Disk Access required",
            instructions: """
                Cursor keeps its usage in a local database this app can only read with Full Disk Access.
                1. Open System Settings → Privacy & Security → Full Disk Access.
                2. Enable “Full LLM Usage Widget” (add it with “+” if it isn’t listed).
                3. Quit and reopen this app, then tap “Check access” below.
                """,
            openSettings: { FullDiskAccess.openSettings() }
        ) {
            let credentials = try CursorStateDB.readCredentials()
            guard !credentials.accessToken.isEmpty else { throw ProviderError.notSignedIn }
            await secrets.saveSecret("1", for: Self.connectedAccount)
        }
    }

    func signOut() async {
        await secrets.clearSecret(for: Self.connectedAccount)
    }

    func fetchUsage() async throws -> ProviderUsage {
        guard await secrets.secret(for: Self.connectedAccount) != nil else {
            throw ProviderError.notSignedIn
        }
        let credentials = try CursorStateDB.readCredentials()
        return try await fetcher.fetch(
            accessToken: credentials.accessToken,
            userId: credentials.userId,
            planBadge: credentials.membershipType
        )
    }
}
