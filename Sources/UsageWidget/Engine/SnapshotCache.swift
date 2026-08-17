import Foundation

/// Reads and writes the last-good `Snapshot` as JSON under
/// `~/Library/Application Support/<bundle-identifier>/`.
struct SnapshotCache: Sendable {
    let directory: URL

    var fileURL: URL { directory.appendingPathComponent("snapshot.json", isDirectory: false) }

    /// Point the cache at an explicit directory (used by self-checks).
    init(directory: URL) {
        self.directory = directory
    }

    /// Point the cache at `~/Library/Application Support/<bundle-identifier>/`.
    init(bundleIdentifier: String, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(directory: base.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    /// Read the last-good `Snapshot`, if one exists.
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    /// Persist a `Snapshot`, creating the directory as needed.
    func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
