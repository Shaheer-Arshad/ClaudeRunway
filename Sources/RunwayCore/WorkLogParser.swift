import Foundation

/// One Claude Code session, reduced to the few lines worth remembering.
struct WorkLogSession: Codable, Equatable {
    let sessionID: String
    /// Working directory the session ran in — the repo it belongs to.
    let cwd: String
    /// Claude Code's own generated session title. The bullet.
    let title: String
    /// Completed todos, in the order they were first completed. Sub-bullets.
    let todos: [String]
    let firstActivity: Date
    let lastActivity: Date
    /// Every local calendar day the session was active on, as `yyyy-MM-dd`.
    /// A session that runs past midnight belongs to both days, so neither one
    /// silently loses half a night's work.
    let days: [String]
    /// First activity *on each day*, keyed the same way as `days`. Ordering a
    /// day's list by `firstActivity` would sort a long-running session resumed
    /// today by when it was originally started, weeks ago.
    let dayStarts: [String: Date]

    /// When work on this session started on `day`, for ordering that day's
    /// list. Falls back to the session's own start for entries decoded from a
    /// cache written before `dayStarts` existed.
    func start(on day: String) -> Date { dayStarts[day] ?? firstActivity }
}

// In an extension so the memberwise initializer survives: `dayStarts` was added
// after the on-disk cache format, and a missing key should cost the ordering
// refinement, not invalidate the whole index.
extension WorkLogSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decode(String.self, forKey: .title)
        todos = try c.decode([String].self, forKey: .todos)
        firstActivity = try c.decode(Date.self, forKey: .firstActivity)
        lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        days = try c.decode([String].self, forKey: .days)
        dayStarts = try c.decodeIfPresent([String: Date].self, forKey: .dayStarts) ?? [:]
    }
}

/// Turns a transcript into a `WorkLogSession`.
///
/// Pure: takes text, returns a value. No file system, no clock. Every rule here
/// is exercised by fixtures in `Tests/WorkLogParserTests.swift`.
///
/// The bullets come from two entry types Claude Code already writes, so the app
/// never has to call a model to summarize anything:
///   - `ai-title`  — a few-word title, present in every session
///   - `TodoWrite` — task-shaped todo text, present in the long ones
enum WorkLogParser {

    /// Returns nil when the transcript has no title or no timestamped activity —
    /// there'd be nothing to render.
    static func parse(_ transcript: String, timeZone: TimeZone = .current) -> WorkLogSession? {
        var sessionID = ""
        var cwd = ""
        var title: String?
        var first: Date?
        var last: Date?
        var dayKeys: [String] = []
        var seenDays = Set<String>()
        var dayStarts: [String: Date] = [:]
        var todos: [String] = []
        var normalizedTodos: [String] = []

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        // Line by line, skipping anything that won't decode. These files are
        // appended to by a live `claude` process, so a half-written final line
        // is an ordinary state, not a corrupt file.
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let id = object["sessionId"] as? String, !id.isEmpty { sessionID = id }
            if let dir = object["cwd"] as? String, !dir.isEmpty { cwd = dir }

            // Last title wins. They're identical in practice; this is the safe
            // rule if Claude Code ever starts revising them mid-session.
            if object["type"] as? String == "ai-title",
               let value = object["aiTitle"] as? String, !value.isEmpty {
                title = value
            }

            if let stamp = object["timestamp"] as? String, let date = Self.date(from: stamp) {
                if first == nil || date < first! { first = date }
                if last == nil || date > last! { last = date }
                let key = dayFormatter.string(from: date)
                if seenDays.insert(key).inserted { dayKeys.append(key) }
                // Transcript lines are usually in order, but a resumed session
                // can interleave; take the minimum rather than the first seen.
                if let existing = dayStarts[key] { dayStarts[key] = min(existing, date) }
                else { dayStarts[key] = date }
            }

            for content in Self.completedTodos(in: object) {
                let normalized = Self.normalize(content)
                guard !normalized.isEmpty else { continue }
                // Claude rewrites the whole todo list on every call, often
                // trimming or expanding an item's wording as it goes. Treat one
                // string containing another as the same task and keep the
                // longer, more informative phrasing.
                if let index = normalizedTodos.firstIndex(where: {
                    $0.contains(normalized) || normalized.contains($0)
                }) {
                    if normalized.count > normalizedTodos[index].count {
                        normalizedTodos[index] = normalized
                        todos[index] = content
                    }
                } else {
                    normalizedTodos.append(normalized)
                    todos.append(content)
                }
            }
        }

        guard let title, let first, let last, !dayKeys.isEmpty else { return nil }

        return WorkLogSession(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            todos: todos,
            firstActivity: first,
            lastActivity: last,
            days: dayKeys.sorted(),
            dayStarts: dayStarts
        )
    }

    // MARK: - Pieces

    /// Digs `TodoWrite` tool calls out of an assistant message and returns the
    /// content of every todo already marked completed.
    private static func completedTodos(in object: [String: Any]) -> [String] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        var found: [String] = []
        for block in content {
            guard block["name"] as? String == "TodoWrite",
                  let input = block["input"] as? [String: Any],
                  let todos = input["todos"] as? [[String: Any]]
            else { continue }

            for todo in todos where todo["status"] as? String == "completed" {
                if let text = todo["content"] as? String, !text.isEmpty { found.append(text) }
            }
        }
        return found
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Transcript timestamps are ISO-8601 with fractional seconds
    /// (`2026-07-27T10:13:52.348Z`), but tolerate the form without them.
    private static func date(from string: String) -> Date? {
        if let date = isoWithFraction.date(from: string) { return date }
        return isoPlain.date(from: string)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}
