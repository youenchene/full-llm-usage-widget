import Foundation

/// Mistral browser sign-in, the same flow the official Vibe CLI uses by default (see
/// docs/mistral-billing-api.md and ADR-0007):
///
///   1. `POST console.mistral.ai/api/vibe/sign-in` with a PKCE challenge → a sign-in page to open
///      and a poll URL.
///   2. Poll until the user approves in the browser (`completed` + `exchange_token`).
///   3. `POST …/vibe/sign-in/{process_id}/exchange` with the token and the PKCE verifier → an
///      **API key**, which then reads the billing API (`MistralBillingFetcher`).
///
/// No client ID is involved: the flow mints a regular key in the user's workspace.
struct MistralSignInClient: Sendable {
    static let browserBase = URL(string: "https://console.mistral.ai")!
    static let apiBase = URL(string: "https://console.mistral.ai/api")!
    /// The CLI polls every 3 seconds.
    static let pollInterval: Duration = .seconds(3)

    struct Process: Sendable {
        let processID: String
        let signInURL: URL
        let pollURL: URL
        let expiresAt: Date
        let verifier: String
    }

    enum PollStatus: Equatable, Sendable {
        case pending
        case completed(exchangeToken: String)
        case expired
        case denied
        case failed(String)
    }

    // MARK: - Flow

    func start() async throws -> Process {
        let pkce = PKCE.generate()
        let data = try await post(
            Self.apiBase.appending(path: "vibe/sign-in"),
            body: ["code_challenge": pkce.challenge, "code_challenge_method": "S256"]
        )
        return try Self.parseProcess(data, verifier: pkce.verifier)
    }

    /// Poll until the user approves, then exchange for the API key.
    func waitForKey(_ process: Process) async throws -> String {
        while Date() < process.expiresAt {
            switch try await poll(process) {
            case .pending:
                try await Task.sleep(for: Self.pollInterval)
            case .completed(let token):
                return try await exchange(process, token: token)
            case .expired:
                throw OAuthError.timeout
            case .denied:
                throw ProviderError.badCredentials("Mistral sign-in was denied in the browser.")
            case .failed(let message):
                throw ProviderError.badCredentials("Mistral sign-in failed: \(message)")
            }
        }
        throw OAuthError.timeout
    }

    private func poll(_ process: Process) async throws -> PollStatus {
        var request = URLRequest(url: process.pollURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        if response.statusCode == 410 { return .expired }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.transport("Mistral sign-in poll: HTTP \(response.statusCode)")
        }
        return Self.parsePoll(data)
    }

    private func exchange(_ process: Process, token: String) async throws -> String {
        let data = try await post(
            Self.apiBase.appending(path: "vibe/sign-in/\(process.processID)/exchange"),
            body: ["exchange_token": token, "code_verifier": process.verifier]
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["api_key"] as? String, !key.isEmpty else {
            throw ProviderError.decoding("Mistral sign-in returned no API key")
        }
        return key
    }

    // MARK: - Pure parsing (exposed for self-checks)

    /// Parse the start response. The sign-in and poll URLs must stay on the console origin (the
    /// CLI enforces the same rule), so a tampered response can't send the key elsewhere.
    static func parseProcess(_ data: Data, verifier: String) throws -> Process {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let processID = json["process_id"] as? String,
              let signIn = (json["sign_in_url"] as? String).flatMap(URL.init(string:)),
              let poll = (json["poll_url"] as? String).flatMap(URL.init(string:)),
              signIn.host == browserBase.host, poll.host == apiBase.host,
              signIn.scheme == "https", poll.scheme == "https" else {
            throw ProviderError.decoding("Unexpected Mistral sign-in response")
        }
        let expires = (json["expires_at"] as? String).flatMap(parseDate) ?? Date().addingTimeInterval(600)
        return Process(processID: processID, signInURL: signIn, pollURL: poll, expiresAt: expires, verifier: verifier)
    }

    static func parsePoll(_ data: Data) -> PollStatus {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("invalid response")
        }
        switch json["status"] as? String {
        case "pending": return .pending
        case "completed":
            guard let token = json["exchange_token"] as? String else { return .failed("no exchange token") }
            return .completed(exchangeToken: token)
        case "expired": return .expired
        case "denied": return .denied
        case "error": return .failed((json["message"] as? String) ?? "error")
        default: return .failed("unknown status")
        }
    }

    /// `expires_at` comes with microseconds and an offset (`2026-11-12T16:46:53.688730+00:00`),
    /// which `ISO8601DateFormatter` rejects, so trim the fraction first.
    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    // MARK: - HTTP

    private func post(_ url: URL, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 403 {
                throw ProviderError.badCredentials("This Mistral workspace can't create API keys. Pick another workspace in the browser, or ask an admin.")
            }
            throw OAuthError.http(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await OAuthHTTP.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
            return (data, http)
        } catch let error as OAuthError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
}
