import Foundation

/// A nicely-cased plan badge (e.g. "Max", "Pro") derived from a provider's raw plan string.
enum PlanName {
    static func badge(from raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro", "individual_pro": return "Pro"
        case "team": return "Team"
        case "enterprise", "ent": return "Enterprise"
        case "max", "max_5x", "max_20x", "max5x", "max20x", "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_free": return "Free"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        case "individual_pro_plus", "pro_plus": return "Pro+"
        case "individual": return "Individual"
        case "business": return "Business"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
