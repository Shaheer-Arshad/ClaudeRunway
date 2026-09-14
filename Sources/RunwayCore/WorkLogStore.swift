import Foundation

/// The sessions of one repo on one day.
struct RepoGroup: Identifiable, Equatable {
    let repo: String
    let sessions: [WorkLogSession]
    var id: String { repo }
}

/// One day's work, grouped and ordered, ready to render.
struct WorkDay: Equatable {
    let date: Date
    let groups: [RepoGroup]
    var isEmpty: Bool { groups.isEmpty }
}

/// Scans `~/.claude/projects` and answers "what did I do on this day?".
///
/// Parsing every transcript on every popover open would be wasteful — the
/// transcripts are large and almost all of them are finished and frozen. So the
/// parse result is cached on disk against each file's size and mtime, and only
/// files that actually changed are read again.
///
/// `@unchecked Sendable` is honest here rather than a shrug: every mutable
/// field is touched only inside `queue`, so the store can be handed to a
/// background load without further ceremony.
final class WorkLogStore: @unchecked Sendable {
    private let projectsDirectory: URL
    private let indexURL: URL
    private let timeZone: TimeZone
    private let queue = DispatchQueue(label: "ClaudeRunway.worklog")

    /// One cached transcript. `size` and `mtime` together are the validity
    /// check: transcripts are append-only, so either changing means new content.
    private struct Entry: Codable {
        let size: Int64
        let mtime: Date
        /// Nil when the transcript parsed to nothing worth showing. Cached all
        /// the same, so a titleless file isn't re-read on every scan.
        let session: WorkLogSession?
    }

    private var index: [String: Entry] = [:]

    init(projectsDirectory: URL? = nil, cacheDirectory: URL? = nil, timeZone: TimeZone = .current) {
        self.projectsDirectory = projectsDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)

        let base = cacheDirectory ?? SupportDirectory.url
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Versioned: the cache stores parsed *results*, so a change to what the
        // parser extracts leaves every untouched transcript holding the old
        // answer forever. Bumping the name discards those in one step.
        self.indexURL = base.appendingPathComponent("worklog-index-v2.json")
        try? FileManager.default.removeItem(at: base.appendingPathComponent("worklog-index.json"))
        self.timeZone = timeZone

        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        }
    }

    // MARK: - Reading

    /// Rescans (parsing only what changed) and returns the grouped day.
    /// Call off the main thread; it touches the disk.
    func day(_ date: Date) -> WorkDay {
        queue.sync {
            refreshIndexLocked()
            let key = Self.dayKey(date, timeZone: timeZone)
            let sessions = index.values.compactMap(\.session).filter { $0.days.contains(key) }
            return WorkDay(date: date, groups: Self.group(sessions, on: key))
        }
    }

    /// Every `yyyy-MM-dd` key that has at least one session on it, across the
    /// whole index — what the calendar dots the month view against. Rescans
    /// first, same as `day(_:)`, so a transcript that just grew a new day
    /// shows up without waiting for that day to be the one on screen.
    func activeDays() -> Set<String> {
        queue.sync {
            refreshIndexLocked()
            return Set(index.values.compactMap(\.session).flatMap(\.days))
        }
    }

    /// How many transcripts the last scan had to parse. Exposed for tests, which
    /// is the only way to prove the cache is actually saving the work.
    private(set) var lastParseCount = 0

    // MARK: - Index

    private func refreshIndexLocked() {
        lastParseCount = 0
        let manager = FileManager.default
        guard let projectDirs = try? manager.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil
        ) else { return }

        var fresh: [String: Entry] = [:]
        for projectDir in projectDirs {
            let files = (try? manager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )) ?? []

            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let mtime = values?.contentModificationDate ?? .distantPast
                let path = file.path

                if let cached = index[path], cached.size == size, cached.mtime == mtime {
                    fresh[path] = cached
                    continue
                }

                // A read can fail transiently — a transcript caught mid-write
                // can have a torn UTF-8 tail. Caching that failure against the
                // file's final size and mtime would hide the session forever,
                // so keep any previous entry and retry on the next scan.
                guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                    if let stale = index[path] { fresh[path] = stale }
                    continue
                }
                lastParseCount += 1
                fresh[path] = Entry(size: size, mtime: mtime,
                                    session: WorkLogParser.parse(text, timeZone: timeZone))
            }
        }

        // Assigning `fresh` also evicts transcripts that have been deleted.
        let changed = lastParseCount > 0 || fresh.count != index.count
        index = fresh
        // Atomic, so a crash mid-write can't leave a truncated index behind,
        // and skipped entirely when nothing moved — most scans change nothing.
        guard changed, let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Grouping

    /// Groups by repo, ordering repos — and the sessions inside them — by when
    /// work on them started. Reading the day top to bottom replays it in order.
    ///
    /// `day` is the `yyyy-MM-dd` key being rendered. Ordering keys off the
    /// session's start *on that day*, not its lifetime start: a session opened
    /// two weeks ago and resumed this afternoon belongs where this afternoon's
    /// work belongs.
    static func group(_ sessions: [WorkLogSession], on day: String) -> [RepoGroup] {
        var byRepo: [String: [WorkLogSession]] = [:]
        for session in sessions {
            byRepo[repoName(for: session.cwd), default: []].append(session)
        }

        return byRepo
            .map { repo, sessions in
                RepoGroup(repo: repo, sessions: sessions.sorted {
                    ($0.start(on: day), $0.sessionID) < ($1.start(on: day), $1.sessionID)
                })
            }
            .sorted {
                ($0.sessions.first?.start(on: day) ?? .distantPast, $0.repo)
                    < ($1.sessions.first?.start(on: day) ?? .distantPast, $1.repo)
            }
    }

    /// The last path component, except for the two directories that aren't
    /// projects at all — work started from the home folder or the Desktop. Those
    /// are real sessions worth showing, but calling them a repo would be a lie.
    static func repoName(for cwd: String) -> String {
        let path = (cwd as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath
        if path == home { return "Home (no repo)" }
        if path == home + "/Desktop" { return "Desktop (no repo)" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }

    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Export

    /// The visible day as plain text, for the Copy buttons — the repo name, one
    /// bullet per session, todos indented beneath.
    ///
    /// Deliberately not markdown: this gets pasted into ordinary text fields —
    /// a standup box, a chat message — where `##` and `-` stay on screen as
    /// literal punctuation instead of turning into headings and bullets. The
    /// markers here are the ones the panel itself draws, so the paste looks
    /// like what was copied.
    ///
    /// No date line either: whatever it lands in already says which day it is.
    static func plainText(_ day: WorkDay) -> String {
        day.groups.map(plainText).joined(separator: "\n")
    }

    /// One repo's sessions, same shape as a slice of the whole day, so copying
    /// a single panel and copying everything produce consistent text.
    static func plainText(_ group: RepoGroup) -> String {
        var lines = [group.repo]
        for session in group.sessions {
            lines.append("• \(session.title)")
            for todo in session.todos { lines.append("   – \(todo)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
