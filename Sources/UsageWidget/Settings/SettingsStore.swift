import Foundation

/// Persists `SettingsState` as JSON under `~/Library/Application Support/<bundle-id>/`.
struct SettingsStore: Sendable {
    let directory: URL

    var fileURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }

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

    func load() -> SettingsState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SettingsState.self, from: data)
    }

    func save(_ settings: SettingsState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
