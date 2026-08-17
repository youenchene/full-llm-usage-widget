import Foundation
import Observation

/// Holds the last USD → EUR rate, refreshing it at most once a day so the menu-bar € total renders
/// instantly and we don't hammer Frankfurter on every poll. A failed refresh keeps the last-good
/// rate (a missing rate just means the menu bar skips the € line).
@MainActor
@Observable
final class ExchangeRateStore {
    private(set) var rate: ExchangeRate?

    private let fetcher: ExchangeRateFetcher
    private let cache: ExchangeRateCache
    private let maxAge: TimeInterval

    init(
        fetcher: ExchangeRateFetcher = ExchangeRateFetcher(),
        cache: ExchangeRateCache,
        maxAge: TimeInterval = 86_400
    ) {
        self.fetcher = fetcher
        self.cache = cache
        self.maxAge = maxAge
        rate = cache.load()
    }

    convenience init(bundleIdentifier: String) {
        self.init(cache: ExchangeRateCache(bundleIdentifier: bundleIdentifier))
    }

    /// EUR per 1 USD, or nil before the first successful fetch.
    var eurPerUSD: Decimal? { rate?.eurPerUSD }

    /// Refresh the rate unless the cached value is still fresh. No-op within `maxAge`.
    func refresh() async {
        if let rate, Date().timeIntervalSince(rate.fetchedAt) < maxAge { return }
        do {
            let value = try await fetcher.fetch()
            let fresh = ExchangeRate(eurPerUSD: value, fetchedAt: Date())
            rate = fresh
            try? cache.save(fresh)
        } catch {
            // Keep the last-good rate.
        }
    }
}

/// Persists the last-good `ExchangeRate` as JSON alongside the snapshot.
struct ExchangeRateCache: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("exchange-rate.json", isDirectory: false) }

    init(directory: URL) {
        self.directory = directory
    }

    init(bundleIdentifier: String, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(directory: base.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    func load() -> ExchangeRate? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExchangeRate.self, from: data)
    }

    func save(_ rate: ExchangeRate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rate)
        try data.write(to: fileURL, options: .atomic)
    }
}
