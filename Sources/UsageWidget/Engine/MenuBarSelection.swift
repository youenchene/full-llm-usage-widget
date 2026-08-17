import Foundation

/// Pure helper for picking the menu-bar's single Progress under a given focus.
enum MenuBarSelection {
    static func progress(plans: [Plan], focus: MenuBarFocus) -> Progress? {
        switch focus {
        case .auto:
            return plans.compactMap(\.progress).max()
        case .pinned(let planID):
            return plans.first { $0.id == planID }?.progress
        }
    }
}
