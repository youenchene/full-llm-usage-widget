import AppKit
import SwiftUI
import Observation

/// Owns the menu-bar `NSStatusItem`, its `NSPopover`, and the on-demand Settings window, and keeps
/// the menu-bar title in sync with the store's focused plan.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: UsageStore
    private let settings: SettingsModel
    private var settingsWindow: NSWindow?

    init(store: UsageStore, providers: [any UsageProvider], settings: SettingsModel) {
        self.store = store
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        super.init()

        configure(providers: providers)
    }

    private func configure(providers: [any UsageProvider]) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: DesignTokens.popoverWidth, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                providers: providers,
                settings: settings,
                onRefresh: { [weak self] in Task { await self?.store.refresh() } },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            button.title = Self.title(for: store.menuBarProgress)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = store.plans
            _ = settings.value
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshTitle()
                self?.observe()
            }
        }
    }

    private func refreshTitle() {
        statusItem.button?.title = Self.title(for: store.menuBarProgress)
    }

    private static func title(for progress: Progress?) -> String {
        progress.map { "\(Int(($0.value * 100).rounded()))%" } ?? "LLM"
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
            rootView: SettingsView(settings: settings, store: store)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
        window.setContentSize(NSSize(width: 420, height: 560))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
