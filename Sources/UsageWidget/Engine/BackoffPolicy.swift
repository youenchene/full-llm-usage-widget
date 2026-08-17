import Foundation

/// Exponential backoff for provider refresh failures.
struct BackoffPolicy: Sendable {
    let initialDelay: Duration
    let maxDelay: Duration
    let multiplier: Double

    static let standard = BackoffPolicy(
        initialDelay: .seconds(5),
        maxDelay: .seconds(900),
        multiplier: 2
    )

    /// Delay after `consecutiveFailures` failures (the first failure → `initialDelay`),
    /// growing by `multiplier` each time and capped at `maxDelay`.
    func delay(afterConsecutiveFailures failures: Int) -> Duration {
        let initialSeconds = initialDelay.inSeconds
        let maxSeconds = maxDelay.inSeconds
        let scaled = initialSeconds * pow(multiplier, Double(max(failures, 0)))
        return .seconds(min(scaled, maxSeconds))
    }
}

private extension Duration {
    var inSeconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
