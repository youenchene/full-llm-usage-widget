import AppKit
import SwiftUI
import Observation

/// Owns the menu-bar `NSStatusItem` and its `NSPopover`, and keeps the menu-bar title in sync
/// with the store's most-urgent plan.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: UsageStore

    init(store: UsageStore, providers: [any UsageProvider]) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: DesignTokens.popoverWidth, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(store: store, providers: providers)
        )

        super.init()

        if let button = statusItem.button {
            button.title = Self.title(for: store.mostUrgentProgress)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        observe(store)
    }

    private func observe(_ store: UsageStore) {
        withObservationTracking {
            _ = store.plans
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshTitle()
                self?.observe(store)
            }
        }
    }

    private func refreshTitle() {
        statusItem.button?.title = Self.title(for: store.mostUrgentProgress)
    }

    private static func title(for progress: Progress?) -> String {
        progress.map { "\(Int(($0.value * 100).rounded()))%" } ?? "LLM"
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
