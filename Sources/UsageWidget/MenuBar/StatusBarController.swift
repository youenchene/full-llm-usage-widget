import AppKit
import SwiftUI

/// Owns the menu-bar `NSStatusItem` and its `NSPopover`.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: DesignTokens.popoverWidth, height: 120)
        popover.contentViewController = NSHostingController(rootView: PopoverRootView())

        super.init()

        if let button = statusItem.button {
            button.title = "LLM"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
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
