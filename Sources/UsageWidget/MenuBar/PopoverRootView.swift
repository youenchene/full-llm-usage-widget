import SwiftUI

/// Empty popover root for Phase 1. Plan cards slot in here in later phases.
struct PopoverRootView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Full LLM Usage Widget")
                .font(.headline)
            Divider()
            Text("No providers wired yet (Phase 1 skeleton).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: DesignTokens.popoverWidth - 32, alignment: .leading)
    }
}
