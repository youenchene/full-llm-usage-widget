import Foundation
import Observation

/// User-facing settings. Populated in Phase 4 (enable/disable providers, budgets,
/// menu-bar focus, thresholds, poll interval, launch-at-login via SMAppService).
@MainActor
@Observable
final class SettingsModel {
    var pollInterval: Duration = .seconds(300)
}
