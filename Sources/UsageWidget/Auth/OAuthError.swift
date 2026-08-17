import Foundation

/// Typed errors from OAuth sign-in flows (authorization + token exchange).
enum OAuthError: Error, Sendable {
    case invalidResponse
    case stateMismatch
    case timeout
    case portUnavailable(UInt16)
    case missingCallbackParameters
    case http(status: Int, body: String)
}

extension OAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The auth server returned an unexpected response."
        case .stateMismatch: "Sign-in state did not match — the attempt may have been tampered with."
        case .timeout: "Timed out waiting for authorization."
        case .portUnavailable(let port): "Could not listen on port \(port) to complete sign-in."
        case .missingCallbackParameters: "The sign-in callback was missing parameters."
        case .http(let status, let body): "Auth request failed (HTTP \(status)): \(body.prefix(120))"
        }
    }
}
