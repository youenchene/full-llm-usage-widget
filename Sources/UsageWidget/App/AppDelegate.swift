import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var compositionRoot: CompositionRoot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon (also set via LSUIElement in the packaged bundle).
        NSApp.setActivationPolicy(.accessory)

        compositionRoot = CompositionRoot()
        compositionRoot?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        compositionRoot?.stop()
    }
}
