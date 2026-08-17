import Foundation

/// The classification of a Plan's consumption signal.
///
/// - `quota`: a provider-imposed limit that resets on a fixed window.
/// - `spend`: consumption measured in currency with no provider-imposed ceiling.
enum Kind: String, Codable, Hashable, Sendable {
    case quota
    case spend
}
