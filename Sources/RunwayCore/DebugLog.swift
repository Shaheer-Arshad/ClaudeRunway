import Foundation

/// Appends timestamped lines to a file next to the cache.
///
/// A menu bar app has no stdout, and the unified log store isn't readable from
/// every context, so a plain file is the one thing that always works.
/// Self-truncating, so it can't grow unbounded on a long-running app.
enum DebugLog {
    private static let queue = DispatchQueue(label: "ClaudeRunway.log")
    private static let maxBytes = 256 * 1024

    static let url: URL = {
        let dir = SupportDirectory.url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    static func write(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let line = "\(stamp)  \(message)\n".data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > maxBytes {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }
}
