import AppKit

// Plain AppKit entry point. A SwiftUI `App` needs at least one scene, and its placeholder
// `Settings { EmptyView() }` scene showed up as a blank window at launch on recent macOS.
// Settings and Accounts windows are opened by `StatusBarController`, so no scene is needed.

// CLI self-check mode: run checks and exit before the UI launches.
if CommandLine.arguments.contains("--check") {
    exit(SelfCheck.run())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar-only: no Dock icon (also set via LSUIElement in the packaged bundle).
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
