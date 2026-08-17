import SwiftUI

@main
struct UsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // CLI self-check mode: run checks and exit before the UI launches.
        if CommandLine.arguments.contains("--check") {
            exit(SelfCheck.run())
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
