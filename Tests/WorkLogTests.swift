import Foundation

/// Fixtures are trimmed copies of real `~/.claude/projects/**/*.jsonl` lines —
/// same field names, same nesting, same timestamp format.

private func userLine(_ stamp: String, cwd: String = "/Users/x/Desktop/skuscraper") -> String {
    """
    {"type":"user","sessionId":"abc","cwd":"\(cwd)","timestamp":"\(stamp)","message":{"role":"user","content":"hi"}}
    """
}

private func titleLine(_ title: String) -> String {
    """
    {"type":"ai-title","aiTitle":"\(title)","sessionId":"abc"}
    """
}

/// Mirrors the real assistant tool-use envelope a TodoWrite call arrives in.
private func todoLine(_ stamp: String, _ todos: [(String, String)]) -> String {
    let items = todos.map { #"{"content":"\#($0.0)","status":"\#($0.1)","activeForm":"doing"}"# }
        .joined(separator: ",")
    return """
    {"type":"assistant","sessionId":"abc","cwd":"/Users/x/Desktop/skuscraper","timestamp":"\(stamp)","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[\(items)]}}]}}
    """
}

private let utc = TimeZone(identifier: "UTC")!

func runWorkLogTests() {

    T.test("extracts title, cwd and timestamps from a normal session") {
        let transcript = [
            userLine("2026-08-10T09:00:00.000Z"),
            titleLine("Build WePlayHandball crawler"),
            userLine("2026-08-10T09:40:00.000Z"),
        ].joined(separator: "\n")

        let session = WorkLogParser.parse(transcript, timeZone: utc)
        T.equal(session?.title, "Build WePlayHandball crawler", "the ai-title becomes the bullet")
        T.equal(session?.sessionID, "abc", "session id")
        T.equal(session?.cwd, "/Users/x/Desktop/skuscraper", "cwd identifies the repo")
        T.equal(session?.days, ["2026-08-10"], "one day of activity")
        T.equal(session?.todos.count, 0, "a session with no todos has no sub-bullets")
    }

    T.test("drops a session with no ai-title") {
        let transcript = userLine("2026-08-10T09:00:00.000Z")
        T.expect(WorkLogParser.parse(transcript, timeZone: utc) == nil,
                 "without a title there is nothing to show")
    }

    T.test("survives a truncated final line") {
        // Exactly what a live `claude` process mid-write looks like on disk.
        let transcript = [
            userLine("2026-08-10T09:00:00.000Z"),
            titleLine("Apply PR 200 fix"),
            #"{"type":"user","sessionId":"abc","timesta"#,
        ].joined(separator: "\n")

        let session = WorkLogParser.parse(transcript, timeZone: utc)
        T.equal(session?.title, "Apply PR 200 fix", "everything before the tear still parses")
    }

    T.test("a session spanning midnight belongs to both days") {
        let transcript = [
            userLine("2026-08-09T23:40:00.000Z"),
            titleLine("Late night refactor"),
            userLine("2026-08-10T00:20:00.000Z"),
        ].joined(separator: "\n")

        T.equal(WorkLogParser.parse(transcript, timeZone: utc)?.days,
                ["2026-08-09", "2026-08-10"],
                "neither day may lose its half of the session")
    }

    T.test("days are bucketed in the given time zone, not UTC") {
        // 23:30 UTC is already the next day in Karachi (+05:00).
        let transcript = [
            userLine("2026-08-09T23:30:00.000Z"),
            titleLine("Evening session"),
        ].joined(separator: "\n")

        let karachi = TimeZone(identifier: "Asia/Karachi")!
        T.equal(WorkLogParser.parse(transcript, timeZone: karachi)?.days, ["2026-08-10"],
                "the log follows the wall clock the work happened on")
    }

    T.test("only completed todos become sub-bullets, in completion order") {
        let transcript = [
            userLine("2026-08-10T09:00:00.000Z"),
            titleLine("Add Jira project picker"),
            todoLine("2026-08-10T09:10:00.000Z", [
                ("Create feat/jira-project-picker branch", "completed"),
                ("Backend: config_options hook", "in_progress"),
                ("Frontend: project picker", "pending"),
            ]),
            todoLine("2026-08-10T09:30:00.000Z", [
                ("Create feat/jira-project-picker branch", "completed"),
                ("Backend: config_options hook", "completed"),
                ("Frontend: project picker", "pending"),
            ]),
        ].joined(separator: "\n")

        let session = WorkLogParser.parse(transcript, timeZone: utc)
        T.equal(session?.todos, ["Create feat/jira-project-picker branch",
                                 "Backend: config_options hook"],
                "pending work is not a record of what got done")
    }

    T.test("rewordings of the same todo collapse to the longest phrasing") {
        // Observed in real transcripts: Claude trims an item's wording between
        // TodoWrite calls, leaving two entries for one task.
        let transcript = [
            userLine("2026-08-10T09:00:00.000Z"),
            titleLine("Scaffold workspace"),
            todoLine("2026-08-10T09:10:00.000Z", [
                ("apps/api skeleton (settings, db)", "completed"),
            ]),
            todoLine("2026-08-10T09:20:00.000Z", [
                ("Create apps/api skeleton (settings, db)", "completed"),
            ]),
        ].joined(separator: "\n")

        let session = WorkLogParser.parse(transcript, timeZone: utc)
        T.equal(session?.todos, ["Create apps/api skeleton (settings, db)"],
                "one task, phrased once, at its most informative")
    }

    // MARK: - Grouping

    T.test("groups a day by repo, ordered by when work started") {
        let early = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let sessions = [
            WorkLogSession(sessionID: "2", cwd: "/Users/x/Desktop/skuscraper", title: "Second repo",
                           todos: [], firstActivity: later, lastActivity: later, days: ["2026-08-10"],
                           dayStarts: ["2026-08-10": later]),
            WorkLogSession(sessionID: "1", cwd: "/Users/x/Desktop/travel-agent", title: "First repo",
                           todos: [], firstActivity: early, lastActivity: early, days: ["2026-08-10"],
                           dayStarts: ["2026-08-10": early]),
        ]

        let groups = WorkLogStore.group(sessions, on: "2026-08-10")
        T.equal(groups.count, 2, "one group per repo")
        T.equal(groups.first?.repo, "travel-agent", "the repo worked in first leads")
        T.equal(groups.last?.repo, "skuscraper", "later repo follows")
    }

    T.test("sessions outside a project are labelled, not disguised as a repo") {
        let now = Date(timeIntervalSince1970: 1_000)
        let home = NSHomeDirectory()
        let sessions = [
            WorkLogSession(sessionID: "1", cwd: "\(home)/Desktop", title: "Odd job",
                           todos: [], firstActivity: now, lastActivity: now, days: ["2026-08-10"],
                           dayStarts: ["2026-08-10": now]),
        ]
        T.equal(WorkLogStore.group(sessions, on: "2026-08-10").first?.repo, "Desktop (no repo)",
                "a bare Desktop session must not look like a project")
    }

    // MARK: - Store

    T.test("the index re-parses only transcripts that changed") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklog-test-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects/-Users-x-Desktop-skuscraper")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = projects.appendingPathComponent("abc.jsonl")
        try [userLine("2026-08-10T09:00:00.000Z"), titleLine("Build crawler")]
            .joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let store = WorkLogStore(projectsDirectory: root.appendingPathComponent("projects"),
                                 cacheDirectory: cache, timeZone: utc)
        let first = store.day(isoDay("2026-08-10"))
        T.equal(first.groups.first?.repo, "skuscraper", "the transcript is found and grouped")
        T.equal(first.groups.first?.sessions.first?.title, "Build crawler", "title survives the round trip")
        T.equal(store.lastParseCount, 1, "the first scan parses the file")

        _ = store.day(isoDay("2026-08-10"))
        T.equal(store.lastParseCount, 0, "an unchanged transcript is never re-read")

        try [userLine("2026-08-10T09:00:00.000Z"), titleLine("Build crawler again")]
            .joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let third = store.day(isoDay("2026-08-10"))
        T.equal(store.lastParseCount, 1, "a touched transcript is re-parsed")
        T.equal(third.groups.first?.sessions.first?.title, "Build crawler again", "and its new title shows")

        T.expect(store.day(isoDay("2026-08-11")).isEmpty, "a day with no sessions is empty")
    }

    T.test("a day is ordered by work done that day, not by session age") {
        // The old session was started two weeks ago and touched again this
        // afternoon; the new one ran this morning. Ordering by lifetime start
        // would put the fortnight-old repo first.
        let old = WorkLogSession(
            sessionID: "old", cwd: "/Users/x/Desktop/long-running", title: "Resumed",
            todos: [], firstActivity: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 9_000),
            days: ["2026-07-27", "2026-08-10"],
            dayStarts: ["2026-07-27": Date(timeIntervalSince1970: 1_000),
                        "2026-08-10": Date(timeIntervalSince1970: 8_000)])
        let fresh = WorkLogSession(
            sessionID: "new", cwd: "/Users/x/Desktop/started-today", title: "Fresh",
            todos: [], firstActivity: Date(timeIntervalSince1970: 5_000),
            lastActivity: Date(timeIntervalSince1970: 5_000),
            days: ["2026-08-10"],
            dayStarts: ["2026-08-10": Date(timeIntervalSince1970: 5_000)])

        let groups = WorkLogStore.group([old, fresh], on: "2026-08-10")
        T.equal(groups.first?.repo, "started-today",
                "the repo actually worked on first that day leads")
        T.equal(groups.last?.repo, "long-running", "the resumed session follows")
    }

    T.test("a transcript that cannot be read keeps its previous entry") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklog-test-\(UUID().uuidString)")
        let projects = root.appendingPathComponent("projects/-Users-x-Desktop-skuscraper")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: projects.appendingPathComponent("abc.jsonl").path)
            try? FileManager.default.removeItem(at: root)
        }

        let transcript = projects.appendingPathComponent("abc.jsonl")
        try [userLine("2026-08-10T09:00:00.000Z"), titleLine("Build crawler")]
            .joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let store = WorkLogStore(projectsDirectory: root.appendingPathComponent("projects"),
                                 cacheDirectory: root.appendingPathComponent("cache"),
                                 timeZone: utc)
        T.equal(store.day(isoDay("2026-08-10")).groups.first?.sessions.first?.title,
                "Build crawler", "cached once while readable")

        // Change the file so the cache is invalidated, then make the read fail.
        try [userLine("2026-08-10T09:00:00.000Z"), titleLine("Build crawler v2")]
            .joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: transcript.path)

        let day = store.day(isoDay("2026-08-10"))
        T.equal(day.groups.first?.sessions.first?.title, "Build crawler",
                "an unreadable transcript falls back to what we already knew, never to nothing")
    }
}

/// A `Date` at midday on the given `yyyy-MM-dd`, in the fixture time zone.
private func isoDay(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = utc
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: "\(text) 12:00")!
}
