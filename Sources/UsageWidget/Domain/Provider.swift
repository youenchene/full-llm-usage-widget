import Foundation

/// A vendor account the widget authenticates against to read usage.
///
/// The seven providers tracked in v1. A Provider can expose more than one `Plan`
/// (OpenCode exposes `Go` and `Zen`).
enum Provider: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case claude
    case codex
    case copilot
    case gemini
    case openCode
    case mistral
    case scaleway
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .gemini: "Gemini"
        case .openCode: "OpenCode"
        case .mistral: "Mistral"
        case .scaleway: "Scaleway"
        case .cursor: "Cursor"
        }
    }
}
