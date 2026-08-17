import Foundation
import AppKit

/// Shared GET helper for usage endpoints. Maps HTTP status codes to `ProviderError` so the engine
/// can render the right state (401 → re-auth, 429 → backoff, else transport).
enum UsageHTTP {
    static let session = URLSession(configuration: .ephemeral)

    static func get(_ request: URLRequest, onUnauthorized: String? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.decoding("Non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            if let onUnauthorized {
                throw ProviderError.badCredentials(onUnauthorized)
            }
            throw ProviderError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.transport("HTTP \(http.statusCode): \(body.prefix(160))")
        }
    }
}

/// Flexible coding key for tolerant decoding of drifting field names.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ string: String) { self.stringValue = string; self.intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

@MainActor
enum Browser {
    /// Open an authorization URL in the user's default browser.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
