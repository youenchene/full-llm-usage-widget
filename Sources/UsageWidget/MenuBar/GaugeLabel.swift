import SwiftUI

/// The menu-bar gauge label: shows the single most-urgent Plan's `Progress`,
/// or a placeholder when nothing is wired.
struct GaugeLabel: View {
    var progress: Progress?
    var placeholder: String = "LLM"

    var body: some View {
        Text(progress.map { "\(Int(($0.value * 100).rounded()))%" } ?? placeholder)
            .font(.system(.body, design: .monospaced))
    }
}
