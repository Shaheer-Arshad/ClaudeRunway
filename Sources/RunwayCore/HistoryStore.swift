import Foundation

/// Persists usage readings so the menu bar has something to show at launch and
/// the popover has a series to draw.
///
/// Two responsibilities that deliberately share a directory:
///   - `cachedSnapshot` — the single most recent reading, restored on launch
///   - `series(...)`     — the rolling history behind the sparkline
final class HistoryStore {
    struct Sample: Codable, Equatable {
        let t: Date
        let session: Double?
        let weekly: Double?
    }

    private let directory: URL
    private let historyURL: URL
    private let snapshotURL: URL
    private let queue = DispatchQueue(label: "ClaudeRunway.history")

    /// Timestamp of the newest sample on disk. Learned from the file once and
    /// maintained in memory afterwards: this is only used to enforce the
    /// spacing floor, and re-reading a day's worth of history to answer "when
    /// was the last one?" is the kind of cost that grows quietly for weeks.
    private var lastSampleAt: Date?
    private var knowsLastSample = false

    /// How many samples the last read had to decode, and how many times the
    /// file was opened. Exposed for tests, which is the only way to prove the
    /// reads stay proportional to the window asked for rather than the file.
    private(set) var lastDecodeCount = 0
    private(set) var fileReads = 0
    /// Bytes actually pulled off disk by the last read. This is the number that
    /// proves the walk is proportional to the window rather than the file;
    /// `lastDecodeCount` alone would pass even for a whole-file read.
    private(set) var bytesRead = 0

    /// Read granularity for the backwards walk. A day of samples at one per
    /// minute is ~1440 lines of ~70 bytes, so 64 KiB covers a typical
    /// sparkline window in a couple of chunks.
    private static let chunkSize = 64 * 1024

    /// Keep the on-disk history bounded; 30 days at one sample/minute is a
    /// worst case of ~43k lines, which stays well under a megabyte.
    private let retention: TimeInterval = 30 * 24 * 3600
    /// The API is polled every 15 min, but guard against duplicate writes.
    private let minSampleSpacing: TimeInterval = 60

    init(directory: URL? = nil) {
        let base = directory ?? SupportDirectory.url
        self.directory = base
        self.historyURL = base.appendingPathComponent("history.jsonl")
        self.snapshotURL = base.appendingPathComponent("last-snapshot.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - Last snapshot

    /// Restored at launch so the menu bar isn't blank while the first fetch runs.
    func loadCachedSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    func save(_ snapshot: UsageSnapshot) {
        queue.async { [self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: snapshotURL, options: .atomic)
            }
            appendSampleLocked(from: snapshot)
        }
    }

    /// Waits for queued writes to land. For tests; the app never needs it.
    func flush() {
        queue.sync {}
    }

    // MARK: - Sparkline series

    private func appendSampleLocked(from snapshot: UsageSnapshot) {
        let sample = Sample(t: snapshot.fetchedAt,
                            session: snapshot.session?.percent,
                            weekly: snapshot.weekly?.percent)

        if let last = lastSampleTimestampLocked(),
           sample.t.timeIntervalSince(last) < minSampleSpacing {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(sample) else { return }
        line.append(0x0A)

        // Creating the file is the only case where a whole-file write is safe.
        // Falling back to `.atomic` on *any* open failure would replace a month
        // of history with a single line the first time the handle can't be had.
        if !FileManager.default.fileExists(atPath: historyURL.path) {
            try? line.write(to: historyURL, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: historyURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            // Existing file we can't open: drop the sample rather than destroy
            // the history. The next poll tries again.
            return
        }

        lastSampleAt = sample.t
        knowsLastSample = true
    }

    private func lastSampleTimestampLocked() -> Date? {
        if !knowsLastSample {
            lastSampleAt = lastSampleOnDiskLocked()?.t
            knowsLastSample = true
        }
        return lastSampleAt
    }

    /// Samples within the given window, oldest first.
    ///
    /// The file holds a month; the sparkline wants a day. Walking backwards
    /// from the end and stopping at the cutoff keeps the cost proportional to
    /// the window rather than to the history — this runs on the main thread
    /// after every fetch.
    func series(since cutoff: Date) -> [Sample] {
        queue.sync { tailLocked(while: { $0.t >= cutoff }) }
    }

    /// Decodes lines from the end of the file for as long as `include` holds,
    /// returning them oldest first. The first sample that fails the test ends
    /// the walk — the file is append-only and in time order, so nothing older
    /// can qualify either.
    private func tailLocked(while include: (Sample) -> Bool) -> [Sample] {
        var kept: [Sample] = []
        forEachSampleBackwardsLocked { sample in
            guard include(sample) else { return false }
            kept.append(sample)
            return true
        }
        return kept.reversed()
    }

    private func lastSampleOnDiskLocked() -> Sample? {
        var last: Sample?
        forEachSampleBackwardsLocked { last = $0; return false }
        return last
    }

    /// Reads the file once and hands decoded samples to `body` newest first,
    /// stopping as soon as it returns false. A line that won't decode is
    /// skipped rather than ending the walk — the file is written by appending,
    /// so a torn final line is an ordinary state.
    private func forEachSampleBackwardsLocked(_ body: (Sample) -> Bool) {
        lastDecodeCount = 0
        bytesRead = 0
        guard let handle = try? FileHandle(forReadingFrom: historyURL) else { return }
        defer { try? handle.close() }
        guard var offset = try? handle.seekToEnd(), offset > 0 else { return }
        fileReads += 1

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Bytes belonging to the line that straddles the start of the chunk we
        // just read; they get prepended to the next (earlier) chunk.
        var carry = Data()

        while offset > 0 {
            let want = UInt64(min(UInt64(Self.chunkSize), offset))
            offset -= want
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(want))
            else { return }
            bytesRead += chunk.count

            var buffer = chunk
            buffer.append(carry)

            // Everything before the first newline in this chunk is an unknown
            // fragment until we've read further back, so hold it in `carry`.
            let lines = splitLines(buffer)
            carry = lines.head
            for line in lines.complete.reversed() {
                guard !line.isEmpty else { continue }
                guard let sample = try? decoder.decode(Sample.self, from: line) else { continue }
                lastDecodeCount += 1
                if !body(sample) { return }
            }
        }

        // Start of file: whatever is left in `carry` is a complete first line.
        if !carry.isEmpty, let sample = try? decoder.decode(Sample.self, from: carry) {
            lastDecodeCount += 1
            _ = body(sample)
        }
    }

    /// Splits on newlines, returning the leading fragment separately from the
    /// lines that are known-complete because a newline preceded them.
    private func splitLines(_ data: Data) -> (head: Data, complete: [Data]) {
        var pieces: [Data] = []
        var start = data.startIndex
        for i in data.indices where data[i] == 0x0A {
            pieces.append(data[start..<i])
            start = data.index(after: i)
        }
        let tail = data[start...]
        guard let head = pieces.first else { return (Data(tail), []) }
        var complete = Array(pieces.dropFirst())
        if !tail.isEmpty { complete.append(Data(tail)) }
        return (head, complete)
    }

    private func allSamplesLocked() -> [Sample] {
        tailLocked(while: { _ in true })
    }

    /// Drops samples past the retention window. Called once at launch — a
    /// full rewrite is cheap at this scale and keeps the format append-only.
    func prune(now: Date = Date()) {
        queue.async { [self] in
            let cutoff = now.addingTimeInterval(-retention)
            let kept = allSamplesLocked().filter { $0.t >= cutoff }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let lines = kept.compactMap { try? encoder.encode($0) }
                .compactMap { String(data: $0, encoding: .utf8) }
            let joined = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            try? joined.write(to: historyURL, atomically: true, encoding: .utf8)
        }
    }
}
