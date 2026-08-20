# Work Log tab — design

**Date:** 2026-08-10
**Status:** Approved

## Problem

Work happens across many repos in Claude Code chat sessions. By the end of a day
there is no record of what got done — only scrollback in a dozen separate
windows. The user wants a per-day view: repo name as a heading, a few words per
task underneath.

## Source of truth

Claude Code already writes every session to
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Two entry types in those
transcripts carry clean, task-shaped text that no LLM call is needed to produce:

| Entry type | Shape | Coverage (measured, 80 transcripts) |
|---|---|---|
| `{"type":"ai-title","aiTitle":…,"sessionId":…}` | Few-word session title | 80/80 sessions |
| `TodoWrite` tool calls with `status:"completed"` | Task-shaped todo text | 11/80 sessions |

Measured facts that shaped the design:

- `ai-title` is written **many times per session but never changes** — it is not
  a running log of sub-tasks, so it cannot be used to split a session.
- Completed todos exist in only 14% of sessions, but those are exactly the long,
  multi-task sessions worth splitting.

**Explicitly rejected:** using the user's own prompts as bullet text. They are
rough and exploratory; they read like thinking-out-loud, not accomplishments.
**Explicitly rejected:** calling an LLM to summarize. No API access, and burning
subscription usage inside a usage-monitoring app is self-defeating.

## Output shape

One bullet per session, from `ai-title`. Completed todos become indented
sub-bullets when the session has them, so multi-task sessions split themselves
and short sessions stay one clean line.

```
skuscraper
  • Build WePlayHandball crawler for Germany
  • Build crawler for Freedom homeware retailer
agent-it-support
  • Add Jira project picker
      – Backend: config_options hook + generic route
      – Frontend: project picker with all five states
```

## Architecture

Three new units, following the existing `Sources/ClaudeUsageCore` (logic) and
`App` (UI) split.

### `WorkLogParser` — `Sources/ClaudeUsageCore/WorkLogParser.swift`

Pure transformation: transcript bytes → `SessionEntry`. No file system access,
no state, no dates from the clock. Everything testable from fixture strings.

```swift
struct SessionEntry: Codable, Equatable {
    let sessionID: String
    let title: String?          // ai-title; nil if the transcript has none
    let todos: [String]         // completed todos, in completion order, deduped
    let firstActivity: Date?
    let lastActivity: Date?
    let activeDays: [DateComponents]  // yyyy-mm-dd of every day with a message
}
```

Rules:

- Parse line by line. A line that fails to decode is skipped, not fatal — these
  files are append-only and being written by another process, so a truncated
  final line is normal, not an error.
- `title` is the **last** `ai-title` seen (they are identical in practice; last
  wins is the safe rule if that ever changes).
- Todos are collected from `TodoWrite` tool-use inputs, taking entries whose
  `status` is `completed`, in first-completed order.
- Todo dedup: normalize each todo to lowercase, collapse runs of whitespace, and
  trim. Then drop it if an already-kept todo contains that normalized form as a
  substring, or is contained by it (keeping the longer of the two). This
  is what collapses the observed pairs like
  `Create apps/api skeleton (settings, db, …)` / `apps/api skeleton (settings, db, …)`.
- `activeDays` derives from message timestamps inside the transcript, in the
  local time zone. A session spanning midnight is active on both days.

### `WorkLogStore` — `Sources/ClaudeUsageCore/WorkLogStore.swift`

Owns the directory scan and the cache.

- Scans `~/.claude/projects/*/*.jsonl`.
- Caches parsed results in `~/Library/Application Support/ClaudeRunway/worklog-index.json`,
  keyed by file path with `size` + `mtime` as the validity check. A transcript
  whose size and mtime are unchanged is never re-parsed.
- `func day(_ date: Date) -> WorkDay` returns the grouped, ordered result:

```swift
struct WorkDay { let date: Date; let groups: [RepoGroup] }
struct RepoGroup { let repo: String; let sessions: [SessionEntry] }
```

- Repo display name: decode the directory name back to a path, take the last
  component. When that path is the user's home or `~/Desktop` — i.e. sessions
  not run inside a project — the group renders as `Desktop (no repo)`.
- Ordering: repos by earliest activity that day; sessions within a repo by their
  first activity that day.
- Sessions with no `ai-title` are dropped (measured: zero such sessions today,
  but the parser must not crash on one).
- Work runs off the main queue; the view is handed a finished `WorkDay`.

### `WorkLogView` — `App/WorkLogView.swift`

- A segmented control at the top of the existing popover switches `Usage` /
  `Work`. `PopoverView` keeps its current content unchanged under `Usage`.
- Header: `‹  Monday 10 August  ›`. Opens on today; the right arrow is disabled
  on today. No forward-dating.
- Body: repo headings with bullets, sub-bullets indented under their session.
  Sub-bullets cap at 8 per session with a `+N more` line so one marathon session
  cannot crowd out the rest of the day. Nothing else is filtered — low-value
  titles like `Start new coding session` are shown as-is, by explicit decision.
- Empty day: "No sessions on this day."
- **Copy** button: writes the whole visible day to the clipboard as markdown —
  `## repo` headings, `- ` bullets, `  - ` sub-bullets — for pasting into a
  standup note or timesheet.
- Read-only. No editing, hiding, or pinning of bullets.

### Refresh

`App/main.swift` already runs a `DirectoryWatcher` on `~/.claude/projects` to
hint usage refreshes. The store hooks the same hint rather than opening a second
watcher; on a hint it re-scans (which re-parses only changed files) and, if the
visible day changed, updates the view.

## Testing

`WorkLogParser` gets unit tests in the existing `Tests` target, over checked-in
fixture transcripts covering:

1. A normal session — title and timestamps extracted.
2. A transcript with no `ai-title`.
3. A truncated final line — parses everything before it, no throw.
4. A session spanning midnight — appears in both days' `activeDays`.
5. Duplicate/substring todos — deduped to one.
6. A session with no todos — empty `todos`, still a valid entry.

`WorkLogStore` gets a test over a temporary directory: index is written, a
second scan with unchanged files does no re-parse, a touched file is re-parsed.

## Out of scope

Editing bullets, a CLI, exporting to a file, week/month views, and any LLM
summarization. Each is a separate change if wanted later.
