import Foundation

/// Shape of an OAuth token endpoint response (both providers return this subset).
struct OAuthTokenResponse: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let id_token: String?
}

enum OAuthHTTP {
    static let session = URLSession(configuration: .ephemeral)

    /// POST a token request and decode the response, mapping failures to typed errors.
    static func send(_ request: URLRequest) async throws -> OAuthTokenResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.http(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw OAuthError.invalidResponse
        }
    }
}

extension CharacterSet {
    /// Allowed characters for an x-www-form-urlencoded value (reserves & = +).
    static let urlFormValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()
}
