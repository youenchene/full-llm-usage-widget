import SwiftUI

/// A short "resets in …" countdown, or nothing when the reset time is unknown.
struct CountdownText: View {
    let resetsAt: Date?

    var body: some View {
        if let resetsAt {
            Text("resets \(Self.string(to: resetsAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    static func string(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 1 { return "in <1m" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 { return remainder > 0 ? "in \(hours)h \(remainder)m" : "in \(hours)h" }
        let days = hours / 24
        let hoursRemainder = hours % 24
        return hoursRemainder > 0 ? "in \(days)d \(hoursRemainder)h" : "in \(days)d"
    }
}
