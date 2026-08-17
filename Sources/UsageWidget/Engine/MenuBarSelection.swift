import Foundation

/// Pure helper for picking the menu-bar's single Progress under a given focus, and for averaging
/// quota-plan usage into the second menu-bar line.
enum MenuBarSelection {
    static func progress(plans: [Plan], focus: MenuBarFocus) -> Progress? {
        switch focus {
        case .auto:
            return plans.compactMap(\.progress).max()
        case .pinned(let planID):
            return plans.first { $0.id == planID }?.progress
        }
    }

    /// Average 0–1 fraction across all quota plans, each represented by its longest-available
    /// window. nil when no quota plan has a usable window.
    static func averageQuotaProgress(plans: [Plan]) -> Progress? {
        let fractions = plans
            .filter { $0.kind == .quota }
            .compactMap { representativeFraction($0) }
        guard !fractions.isEmpty else { return nil }
        return Progress(value: fractions.reduce(0, +) / Double(fractions.count))
    }

    /// The 0–1 fraction of a quota plan's representative window, preferring "monthly", then
    /// "weekly", then "5h", then whatever window remains (Codex sometimes exposes only its "5h"
    /// window). Unlimited windows are skipped — they have no meaningful "used".
    private static func representativeFraction(_ plan: Plan) -> Double? {
        let windows = plan.limitWindows.filter { !$0.unlimited }
        for label in ["monthly", "weekly", "5h"] {
            if let window = windows.first(where: { $0.label == label }) {
                return window.progress.value
            }
        }
        return windows.first?.progress.value
    }
}
