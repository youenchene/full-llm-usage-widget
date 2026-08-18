import Foundation
import Security

/// Obtains a short-lived OAuth2 access token from a Google service-account JSON key using the
/// documented JWT-bearer grant (RFC 7523) — the standard server-to-server flow for BigQuery.
///
/// The private key is parsed from the PEM inside the service-account JSON and used to sign a JWT
/// assertion (RS256) via the Security framework. The resulting access token is used only for
/// BigQuery queries and is never persisted. No API key, browser cookie, or undocumented endpoint
/// is involved.
struct GoogleServiceAccountTokenFetcher: Sendable {
    static let defaultTokenURI = URL(string: "https://oauth2.googleapis.com/token")!
    static let bigQueryReadOnlyScope = "https://www.googleapis.com/auth/bigquery.readonly"

    /// The fields of a service-account JSON key the widget needs.
    struct ServiceAccount: Sendable {
        let clientEmail: String
        let privateKeyPEM: String
        let tokenURI: URL
    }

    /// Parse a service-account JSON key. Throws `badCredentials` when the shape is wrong.
    static func parseServiceAccount(_ json: String) throws -> ServiceAccount {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientEmail = object["client_email"] as? String, !clientEmail.isEmpty,
              let privateKey = object["private_key"] as? String, !privateKey.isEmpty else {
            throw ProviderError.badCredentials(
                "Invalid Google service account JSON — expected a key with client_email and private_key."
            )
        }
        let tokenURI = (object["token_uri"] as? String).flatMap(URL.init(string:)) ?? defaultTokenURI
        return ServiceAccount(clientEmail: clientEmail, privateKeyPEM: privateKey, tokenURI: tokenURI)
    }

    /// Exchange the service account for a short-lived access token.
    static func accessToken(serviceAccountJSON: String) async throws -> String {
        let account = try parseServiceAccount(serviceAccountJSON)
        let jwt = try makeJWT(account)
        return try await exchange(jwt: jwt, tokenURI: account.tokenURI)
    }

    // MARK: - JWT assertion

    static func jwtHeader() -> String {
        base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    }

    static func jwtClaims(account: ServiceAccount, now: Int) throws -> String {
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": bigQueryReadOnlyScope,
            "aud": account.tokenURI.absoluteString,
            "iat": now,
            "exp": now + 3600
        ]
        return base64URL(try JSONSerialization.data(withJSONObject: claims))
    }

    static func makeJWT(_ account: ServiceAccount) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let signingInput = "\(jwtHeader()).\(try jwtClaims(account: account, now: now))"
        let signature = try signRS256(Data(signingInput.utf8), privateKeyPEM: account.privateKeyPEM)
        return "\(signingInput).\(base64URL(signature))"
    }

    /// RS256-sign `data` with the PEM private key via the Security framework. Google service-account
    /// keys are PKCS#8 PEM, which is the format `SecKeyCreateWithData` defaults to.
    static func signRS256(_ data: Data, privateKeyPEM: String) throws -> Data {
        guard let der = pemToDER(privateKeyPEM) else {
            throw ProviderError.badCredentials("Invalid service account private key.")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw ProviderError.badCredentials("Could not import the service account private key.")
        }
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error
        ) as Data? else {
            throw ProviderError.badCredentials("Could not sign the service account assertion.")
        }
        return signature
    }

    /// Strip PEM armor, returning the DER bytes.
    static func pemToDER(_ pem: String) -> Data? {
        let base64 = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        return Data(base64Encoded: base64)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token exchange

    static func exchange(jwt: String, tokenURI: URL) async throws -> String {
        var request = URLRequest(url: tokenURI)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let assertion = jwt.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? jwt
        request.httpBody = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)"
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await UsageHTTP.session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.decoding("Non-HTTP response from the Google token endpoint")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.badCredentials(
                "Google rejected the service account (HTTP \(http.statusCode)): \(body.prefix(160))"
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw ProviderError.decoding("Google token response missing access_token")
        }
        return token
    }
}