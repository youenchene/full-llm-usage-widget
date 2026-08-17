import Foundation

/// Persists the set of "already notified" cycle keys (plan id → cycle key) so a notification
/// fires once per window/reset cycle, even across launches.
struct NotificationCycleStore: Sendable {
    let directory: URL

    var fileURL: URL { directory.appendingPathComponent("notifications.json", isDirectory: false) }

    /// Point the store at an explicit directory (used by self-checks).
    init(directory: URL) {
        self.directory = directory
    }

    /// Point the store at `~/Library/Application Support/<bundle-id>/`.
    init(bundleIdentifier: String, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(directory: base.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func save(_ notified: [String: String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(notified)
        try data.write(to: fileURL, options: .atomic)
    }
}
