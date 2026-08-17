import AppKit
import SwiftUI
import Observation

/// Owns the menu-bar `NSStatusItem`, its `NSPopover`, and the on-demand Settings/Accounts windows.
/// The status item hosts a two-line label (total € spent + average quota %) that SwiftUI keeps in
/// sync with the store via `@Observable`.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: UsageStore
    private let settings: SettingsModel
    private let providers: [any UsageProvider]
    private var settingsWindow: NSWindow?
    private var accountsWindow: NSWindow?
    private var labelHosting: NSHostingView<MenuBarSpendLabel>?

    init(store: UsageStore, providers: [any UsageProvider], settings: SettingsModel) {
        self.store = store
        self.settings = settings
        self.providers = providers
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        super.init()

        configure()
    }

    private func configure() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: DesignTokens.popoverWidth, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                providers: providers,
                settings: settings,
                onRefresh: { [weak self] in Task { await self?.store.refresh(force: true) } },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onOpenAccounts: { [weak self] in self?.openAccounts() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        // A two-line label can't render in `button.title`, so host the SwiftUI label in a custom
        // view and drive the popover from a click gesture on it. The hosting view starts with a
        // zero frame, so it's sized to its content before assigning — otherwise the status item
        // collapses to nothing.
        let hosting = NSHostingView(rootView: MenuBarSpendLabel(store: store))
        hosting.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePopover(_:))))
        labelHosting = hosting
        statusItem.view = hosting
        resizeLabel()
        observe()
    }

    /// Resize the hosted label to fit its current SwiftUI content, and re-measure the status item
    /// so it tracks the label as values change (a custom view isn't auto-sized after assignment).
    private func resizeLabel() {
        guard let hosting = labelHosting else { return }
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 1), height: max(fitting.height, 22))
        hosting.setFrameSize(size)
        statusItem.length = size.width
    }

    /// Re-run whenever the label's inputs change so the status item width stays in sync.
    private func observe() {
        withObservationTracking {
            _ = store.totalSpentEUR
            _ = store.menuBarProgress
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.resizeLabel()
                self?.observe()
            }
        }
    }

    // MARK: - Settings window

    /// Open (or focus) the Settings window. Hosted here so it can be created on demand and share
    /// the live store/settings, without relying on a SwiftUI `Settings` scene.
    func openSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(
            rootView: SettingsView(settings: settings)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
        window.setContentSize(NSSize(width: 420, height: 560))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Accounts window

    /// Open (or focus) the Accounts window for signing in and out of providers.
    func openAccounts() {
        if let accountsWindow, accountsWindow.isVisible {
            accountsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(
            rootView: ConnectionsView(store: store, providers: providers, settings: settings)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Accounts"
        window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
        window.setContentSize(NSSize(width: 380, height: 480))
        window.center()
        accountsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let view = statusItem.view {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
