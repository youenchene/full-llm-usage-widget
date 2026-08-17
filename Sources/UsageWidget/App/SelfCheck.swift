import Foundation

/// In-process self-checks exercised by `run.sh --check` (and the packaged `--check` flag).
///
/// Phase 4 grows this into a full suite (parsing, PKCE, backoff, snapshot round-trip).
enum SelfCheck {
    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("PASS \(name)")
            } else {
                print("FAIL \(name)")
                failures += 1
            }
        }

        // Backoff: grows exponentially and caps at maxDelay.
        let policy = BackoffPolicy.standard
        check("backoff.initial", policy.delay(afterConsecutiveFailures: 0) == .seconds(5))
        check("backoff.grows", policy.delay(afterConsecutiveFailures: 1) == .seconds(10))
        check("backoff.caps", policy.delay(afterConsecutiveFailures: 20) == .seconds(900))

        // Progress: clamps to 0...1 and handles a zero limit.
        check("progress.normal", Progress(used: 5, limit: 10).value == 0.5)
        check("progress.over-limit-clamps", Progress(used: 15, limit: 10).value == 1)
        check("progress.zero-limit", Progress(used: 0, limit: 0).value == 0)
        check("progress.negative-clamps", Progress(value: -0.5).value == 0)

        // Snapshot: JSON round-trip.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-widget-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = SnapshotCache(directory: dir)
        let plan = Plan(
            id: "opencode.go",
            provider: .openCode,
            name: "OpenCode Go",
            kind: .quota,
            limitWindows: [
                LimitWindow(
                    label: "rolling",
                    used: 42,
                    limit: 100,
                    resetsAt: Date(timeIntervalSince1970: 1_752_000_000)
                )
            ]
        )
        let snapshot = Snapshot(plans: [plan], fetchedAt: Date())
        do {
            try cache.save(snapshot)
            let loaded = cache.load()
            check("snapshot.roundtrip", loaded?.plans == snapshot.plans)
        } catch {
            print("FAIL snapshot.roundtrip: \(error)")
            failures += 1
        }

        print(failures == 0 ? "Self-check OK" : "Self-check FAILED (\(failures) failure(s))")
        return failures == 0 ? 0 : 1
    }
}
