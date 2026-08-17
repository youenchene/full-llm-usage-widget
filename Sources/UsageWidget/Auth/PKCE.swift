import Foundation
import CryptoKit
import Security

/// A PKCE code challenge plus an anti-CSRF `state`, generated per sign-in attempt.
struct PKCEChallenge: Sendable {
    let verifier: String   // 43-char base64url (from 32 random bytes)
    let challenge: String  // base64url(SHA256(verifier))
    let state: String      // base64url(32 random bytes)
}

enum PKCE {
    static func generate() -> PKCEChallenge {
        let verifier = randomURLSafe(byteCount: 32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(byteCount: 32)
        return PKCEChallenge(verifier: verifier, challenge: challenge, state: state)
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
