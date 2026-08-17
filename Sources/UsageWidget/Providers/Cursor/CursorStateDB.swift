import Foundation
import SQLite3

/// The Cursor credentials the widget needs to read usage, gathered from Cursor's local state.
///
/// Everything here is reverse-engineered and undocumented (see `docs/cursor-full-disk-access.md`),
/// so the reader is tolerant: it opens read-only and treats a missing key or an unreadable file as
/// a clean `nil` / error rather than crashing.
struct CursorCredentials: Sendable {
    let accessToken: String
    let membershipType: String?
    let userId: String?
}

/// Read-only access to Cursor's local `state.vscdb` SQLite database — a VS Code-style key/value
/// store (`ItemTable` with a `key` column and a `value` column). Requires Full Disk Access because
/// the file lives under `~/Library/Application Support/Cursor/` (TCC-protected).
///
/// Cursor runs WAL journaling and the DB can grow large, so every open is `SQLITE_OPEN_READONLY`
/// with a busy timeout and `PRAGMA query_only` — we never take a write lock on Cursor's DB.
struct CursorStateDB: Sendable {
    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    static let sentryDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/sentry")

    /// `SQLITE_TRANSIENT` (the C macro `((sqlite3_destructor_type)-1)`) isn't imported into Swift;
    /// reconstruct it so `sqlite3_bind_text` copies the value instead of borrowing it.
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Read a single string value from `ItemTable`. Returns `nil` when the key is absent; throws
    /// `ProviderError.permissionDenied` when the file can't be opened (no Full Disk Access, Cursor
    /// not installed, or an unreadable DB).
    static func readString(key: String, at url: URL) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ProviderError.permissionDenied(
                "Can't read Cursor's database. Is Cursor installed, and does this app have Full Disk Access?"
            )
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw ProviderError.permissionDenied("Cursor's database has an unexpected schema.")
        }
        defer { sqlite3_finalize(stmt) }

        _ = key.withCString { cString in
            sqlite3_bind_text(stmt, 1, cString, -1, Self.sqliteTransient)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // The value may be stored as TEXT or BLOB; handle both.
        if let cString = sqlite3_column_text(stmt, 0) {
            return String(cString: cString)
        }
        if let blob = sqlite3_column_blob(stmt, 0) {
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// Gather the credentials needed to query Cursor usage. Throws `.notSignedIn` when the token is
    /// absent/empty (Cursor signed out), or `.permissionDenied` when the DB is unreadable.
    static func readCredentials(at url: URL = databaseURL) throws -> CursorCredentials {
        guard let token = try readString(key: "cursorAuth/accessToken", at: url),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.notSignedIn
        }
        let membership = try readString(key: "cursorAuth/stripeMembershipType", at: url)
        let userId = resolveUserId(accessToken: token)
        return CursorCredentials(accessToken: token, membershipType: membership, userId: userId)
    }

    /// Best-effort `user_…` id: Cursor's sentry JSON (`scope.user.id`), else the token's JWT `sub`
    /// claim. Returns nil when neither resolves (the USD credit endpoint doesn't need it).
    static func resolveUserId(accessToken: String) -> String? {
        if let fromSentry = readSentryUserId() { return fromSentry }
        return jwtSubject(accessToken)
    }

    private static func readSentryUserId() -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sentryDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let id = findUserId(in: json) { return id }
        }
        return nil
    }

    /// Walk the JSON tree for a `user_…` string nested under a `user` object's `id` key.
    private static func findUserId(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let user = dict["user"] as? [String: Any],
               let id = user["id"] as? String, id.hasPrefix("user_") {
                return id
            }
            for value in dict.values {
                if let found = findUserId(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = findUserId(in: value) { return found }
            }
        }
        return nil
    }

    /// Decode a JWT's payload `sub`/`user_id` claim. Tolerant: returns nil for JWE (encrypted) or
    /// otherwise non-JWT tokens.
    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let sub = json["sub"] as? String { return sub }
        if let userId = json["user_id"] as? String { return userId }
        return nil
    }
}
