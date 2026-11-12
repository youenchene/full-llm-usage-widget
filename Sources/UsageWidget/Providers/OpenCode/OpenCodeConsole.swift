import Foundation

/// A bearer credential for the OpenCode Console: either a device-login access token or a personal
/// API key (`oc_sk_…`, or a legacy `sk-…` key, which still works for Go). `workspaceID` (`wrk_…`)
/// picks the workspace. The Console API needs it; the Go usage endpoint treats it as optional.
struct OpenCodeCredential: Sendable {
    let bearer: String
    let workspaceID: String?
}

/// Shared endpoints and HTTP plumbing for the OpenCode Console (formerly "Zen"; see
/// docs/opencode-console.md). The Console API lives under `/console/api/…` and reads the workspace
/// from `x-org-id`. The Go usage endpoint lives on the inference origin and reads it from
/// `x-opencode-org-id`.
enum OpenCodeConsole {
    static let origin = "https://opencode.ai"
    static let server = "https://opencode.ai/console"

    /// We identify ourselves honestly. The Console reads the User-Agent only for analytics.
    static let userAgent = "full-llm-usage-widget"

    static func request(_ url: URL, credential: OpenCodeCredential, workspaceHeader: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let workspace = credential.workspaceID, !workspace.isEmpty {
            request.setValue(workspace, forHTTPHeaderField: workspaceHeader)
        }
        return request
    }

    /// GET that treats 403/404 as "nothing to show here" (`nil`): Go refuses a workspace without a
    /// subscription, and the Console refuses budgets to keys that can't read them. 401 throws
    /// `.unauthorized` so the caller can refresh a login token or flag a bad key.
    static func getOptional(_ request: URLRequest) async throws -> Data? {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await UsageHTTP.session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.decoding("Non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 403, 404: return nil
        case 401: throw ProviderError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.transport("HTTP \(http.statusCode): \(body.prefix(160))")
        }
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
