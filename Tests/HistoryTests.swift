import Foundation

/// The history file grows all day and is read on the main thread, so what
/// matters here is not just the values returned but how much work it took to
/// return them. `lastDecodeCount` is the only way to prove that.
func runHistoryTests() {

    /// A store over a throwaway directory, pre-filled with `count` samples one
    /// minute apart ending `now`.
    func store(samples count: Int, now: Date = Date()) -> (HistoryStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("historytests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = (0..<count).map { i -> String in
            let sample = HistoryStore.Sample(t: now.addingTimeInterval(Double(i - count + 1) * 60),
                                             session: Double(i % 100), weekly: 10)
            return String(data: try! encoder.encode(sample), encoding: .utf8)!
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)

        return (HistoryStore(directory: dir), dir)
    }

    T.test("series decodes only the requested window, not the whole file") {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let (history, dir) = store(samples: 5000, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hour = history.series(since: now.addingTimeInterval(-3600))
        T.equal(hour.count, 61, "one sample a minute for the last hour, inclusive")
        T.expect(hour.first!.t < hour.last!.t, "oldest first")
        T.expect(history.lastDecodeCount <= 62,
                 "walking back from the end must not decode all 5000 lines — decoded \(history.lastDecodeCount)")
    }

    T.test("series reads a window's worth of bytes, not the whole file") {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let (history, dir) = store(samples: 20_000, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("history.jsonl").path
        let fileSize = (try! FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue
        T.expect(fileSize > 512 * 1024, "the fixture needs to be big enough for the claim to mean something")

        _ = history.series(since: now.addingTimeInterval(-3600))
        T.expect(history.bytesRead < fileSize / 4,
                 "an hour's window must not pull the whole \(fileSize)-byte file off disk — read \(history.bytesRead)")
    }

    T.test("a sample that spans a chunk boundary still decodes") {
        // 64 KiB of samples guarantees lines straddling the read boundary; if
        // the carry-over between chunks were wrong, some would silently vanish.
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let (history, dir) = store(samples: 3000, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }

        let all = history.series(since: now.addingTimeInterval(-3000 * 60))
        T.equal(all.count, 3000, "every line survives the chunked backwards walk")
        T.expect(all.first!.t < all.last!.t, "oldest first")
        T.equal(all.last!.t, now, "the newest sample is the last one")
    }

    T.test("an unopenable history file is never replaced by a single sample") {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let (history, dir) = store(samples: 500, now: now)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: dir.appendingPathComponent("history.jsonl").path)
            try? FileManager.default.removeItem(at: dir)
        }

        let file = dir.appendingPathComponent("history.jsonl")
        let before = (try! Data(contentsOf: file)).count
        // Read-only: `FileHandle(forWritingTo:)` fails, which used to fall
        // through to an atomic whole-file write of one line.
        try! FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)

        history.save(UsageSnapshot(buckets: [], fetchedAt: now.addingTimeInterval(600)))
        history.flush()

        T.equal((try! Data(contentsOf: file)).count, before,
                "a failed append must leave the history exactly as it was")
    }

    T.test("an empty window costs one decode, not a file scan") {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let (history, dir) = store(samples: 5000, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }

        T.equal(history.series(since: now.addingTimeInterval(3600)).count, 0, "nothing in the future")
        T.expect(history.lastDecodeCount <= 1, "stop at the first sample older than the cutoff")
    }

    T.test("appending remembers the last timestamp instead of re-reading the file") {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let (history, dir) = store(samples: 500, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }

        func snapshot(_ at: Date) -> UsageSnapshot {
            UsageSnapshot(buckets: [LimitBucket(key: "session", displayName: "s",
                                                percent: 50, resetsAt: nil)], fetchedAt: at)
        }

        history.save(snapshot(now.addingTimeInterval(60)))
        history.flush()
        let afterFirst = history.fileReads

        for i in 2...5 { history.save(snapshot(now.addingTimeInterval(Double(i) * 60))) }
        history.flush()

        T.equal(history.fileReads, afterFirst,
                "only the first append needs to learn the last timestamp from disk")
        T.equal(history.series(since: now.addingTimeInterval(1)).count, 5, "all five appended samples still landed")
    }

    T.test("samples closer together than the floor are dropped") {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let (history, dir) = store(samples: 10, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }

        func snapshot(_ at: Date) -> UsageSnapshot {
            UsageSnapshot(buckets: [LimitBucket(key: "session", displayName: "s",
                                                percent: 50, resetsAt: nil)], fetchedAt: at)
        }

        history.save(snapshot(now.addingTimeInterval(10)))   // 10s after the last — too soon
        history.save(snapshot(now.addingTimeInterval(90)))   // 90s — accepted
        history.flush()

        T.equal(history.series(since: now.addingTimeInterval(1)).count, 1,
                "only the sample past the 60s floor is kept")
    }
}
