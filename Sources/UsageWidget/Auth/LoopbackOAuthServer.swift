import Foundation
import Network

struct LoopbackResult: Sendable {
    let code: String
    let state: String
}

/// A one-shot local HTTP listener that captures an OAuth redirect to `http://127.0.0.1:<port><path>`.
/// Used for Codex, whose registered redirect URI is a fixed loopback address. Single-resume by design:
/// the first of {callback, failure, timeout} wins and the listener is torn down.
final class LoopbackOAuthServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.micrix.full-llm-usage-widget.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<LoopbackResult, Error>?
    private var finished = false

    init(port: UInt16 = 1455) {
        self.port = port
    }

    func waitForCallback(timeout: TimeInterval = 180) async throws -> LoopbackResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.continuation = cont
                self.startListener()
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(OAuthError.timeout))
                }
            }
        }
    }

    func stop() {
        queue.async { self.teardown() }
    }

    // MARK: - Private (all on `queue`)

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                finish(.failure(OAuthError.portUnavailable(port)))
                return
            }
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(.failure(OAuthError.portUnavailable(self?.port ?? 0))) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            finish(.failure(OAuthError.portUnavailable(port)))
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let target = data.flatMap { Self.requestTarget(from: $0) }
            let (code, state) = Self.parseCodeAndState(fromTarget: target)
            self.respond(on: connection, success: code != nil)
            if let code, let state {
                self.finish(.success(LoopbackResult(code: code, state: state)))
            } else {
                self.finish(.failure(OAuthError.missingCallbackParameters))
            }
        }
    }

    private func respond(on connection: NWConnection, success: Bool) {
        let title = success ? "Signed in" : "Sign-in failed"
        let message = success
            ? "You can close this tab and return to the widget."
            : "Something went wrong. Return to the app and try again."
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,system-ui;background:#020617;color:#e2e8f0;display:flex;height:100vh;margin:0;align-items:center;justify-content:center">
        <div style="text-align:center"><h2 style="font-weight:600">\(title)</h2><p style="color:#94a3b8">\(message)</p></div>
        </body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<LoopbackResult, Error>) {
        guard !finished else { return }
        finished = true
        let cont = continuation
        continuation = nil
        teardown()
        switch result {
        case .success(let value): cont?.resume(returning: value)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    private func teardown() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Parsing helpers

    /// Extract the request target from the HTTP request line: "GET /auth/callback?... HTTP/1.1".
    private static func requestTarget(from data: Data) -> String? {
        guard let request = String(data: data, encoding: .utf8),
              let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private static func parseCodeAndState(fromTarget target: String?) -> (String?, String?) {
        guard let target,
              let comps = URLComponents(string: "http://localhost\(target)") else { return (nil, nil) }
        let code = comps.queryItems?.first { $0.name == "code" }?.value
        let state = comps.queryItems?.first { $0.name == "state" }?.value
        return (code, state)
    }
}
