import Foundation

/// Where the app keeps its own state: the sparkline history, the last snapshot,
/// the work log index, and the debug log.
///
/// One place rather than three, because the app was renamed from
/// "ClaudeUsageBar" to "Claude Runway" and the old directory has to be carried
/// forward exactly once. Three independent copies of that logic would be three
/// chances to migrate half of it.
public enum SupportDirectory {
    private static let currentName = "ClaudeRunway"
    private static let legacyName = "ClaudeUsageBar"

    /// Created on first access, migrating the pre-rename directory if one is
    /// there and we haven't already moved it.
    public static let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent(currentName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyName, isDirectory: true)

        let manager = FileManager.default
        // Only when the new directory doesn't exist yet: a `moveItem` onto an
        // existing path fails, and a half-merge would be worse than either.
        if !manager.fileExists(atPath: current.path),
           manager.fileExists(atPath: legacy.path) {
            try? manager.moveItem(at: legacy, to: current)
        }

        try? manager.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }()
}
