import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp` (not a deprecated Login Item).
///
/// `SMAppService` is the OS source of truth: the toggle reflects `status` rather than a stored
/// flag, so it can't drift from reality. Registering a dev build outside /Applications may fail;
/// the error is surfaced so the user knows why.
struct LaunchAtLogin {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app for launch at login. Throws on failure.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
