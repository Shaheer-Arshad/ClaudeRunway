import AppKit
import SwiftUI

/// Posted when Claude Code touches `~/.claude/projects`, and when the popover
/// opens. Both mean the same thing to the work log: the day may have grown.
extension Notification.Name {
    static let claudeActivity = Notification.Name("ClaudeRunway.claudeActivity")
}

/// Loads a day off the main thread and republishes it for the view.
@MainActor
final class WorkLogModel: ObservableObject {
    @Published private(set) var day: WorkDay?

    /// Every day, across the whole history, that has at least one session —
    /// what the calendar dots. Loaded alongside `day`, not on demand from the
    /// calendar itself: the calendar can be opened and paged without ever
    /// touching the store directly.
    @Published private(set) var activeDays: Set<String> = []

    /// True while a scan is in flight, so the refresh button can show that the
    /// tap landed. A rescan of an unchanged tree finishes in milliseconds, and
    /// a control that flickers reads as broken — so the spin is held briefly.
    @Published private(set) var isLoading = false

    /// Days back from *today*, never positive. Stored as an offset rather than
    /// an absolute date so the view rolls over at midnight on its own: an app
    /// left open overnight kept pointing at the day it launched on, which left
    /// the header reading "Yesterday" with Today unreachable.
    @Published private(set) var dayOffset = 0

    /// The day currently being shown, resolved against the clock each time.
    var date: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
    }

    private let store = WorkLogStore()
    private let queue = DispatchQueue(label: "ClaudeRunway.worklog.ui", qos: .userInitiated)

    /// Set when activity arrived while the popover was hidden. Plain state, not
    /// `@Published`: noticing that the day went stale must not itself redraw.
    private var staleWhileHidden = false

    var isOnToday: Bool { dayOffset == 0 }

    func load() {
        let target = date
        isLoading = true
        let started = Date()
        queue.async { [store] in
            let day = store.day(target)
            let activeDays = store.activeDays()
            Task { @MainActor [weak self] in
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 0.35 { try? await Task.sleep(for: .seconds(0.35 - elapsed)) }
                guard let self else { return }
                self.isLoading = false
                self.activeDays = activeDays
                // A fast arrow-tap can land two loads out of order; keep only
                // the one the user is actually looking at.
                guard Calendar.current.isDate(self.date, inSameDayAs: target) else { return }
                self.day = day
            }
        }
    }

    /// Claude Code touched the transcripts. Rescanning means stat-ing every
    /// project directory and re-parsing whatever grew — real work, and pointless
    /// for a panel that isn't on screen, so a hidden view only remembers that it
    /// owes itself a reload.
    func noteActivity(visible: Bool) {
        if visible { load() } else { staleWhileHidden = true }
    }

    func becameVisible() {
        // Reload when transcripts changed while hidden, and also when the
        // clock has crossed midnight since the last load — the same offset
        // now means a different day.
        let rolledOver = day.map { !Calendar.current.isDate($0.date, inSameDayAs: date) } ?? true
        guard staleWhileHidden || rolledOver else { return }
        staleWhileHidden = false
        load()
    }

    /// Rescan now. The watcher and the visibility hooks cover the common cases,
    /// but a transcript written moments ago can still be behind the FSEvents
    /// debounce, and this is the button for that.
    func refresh() {
        staleWhileHidden = false
        load()
    }

    func step(_ days: Int) {
        show(offset: dayOffset + days)
    }

    /// Move to an absolute date, which is what a calendar hands back. Converted
    /// straight to an offset so the view keeps rolling over at midnight on its
    /// own rather than pinning itself to the date that was picked.
    func jump(to target: Date) {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: target)).day ?? 0
        show(offset: days)
    }

    private func show(offset: Int) {
        // Never walk into the future — there is nothing there by definition.
        let moved = min(offset, 0)
        guard moved != dayOffset else { return }
        dayOffset = moved
        day = nil
        load()
    }

    func copyToPasteboard() {
        guard let day else { return }
        Self.copy(WorkLogStore.plainText(day))
    }

    func copyToPasteboard(_ group: RepoGroup) {
        Self.copy(WorkLogStore.plainText(group))
    }

    private static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// What you did, grouped by the repo you did it in.
///
/// Every line here was written by Claude Code as it worked — session titles and
/// completed todos already in the transcripts — so nothing has to be summarized
/// at read time and nothing costs usage to display.
struct WorkLogView: View {
    /// Owned by `PopoverView`, not here. The tab `switch` removes this view
    /// from the hierarchy, so a `@StateObject` died on every tab switch —
    /// resetting the day back to Today and replaying the whole scan.
    @ObservedObject var model: WorkLogModel
    @EnvironmentObject private var visibility: PopoverVisibility
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    /// The repo whose own Copy button was just pressed, for its tick.
    @State private var copiedRepo: String?
    @State private var pickingDate = false

    /// One long session must not push the rest of the day off the bottom.
    private let todoLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dayHeader
            if pickingDate { calendar }
            content
        }
        .onAppear { model.becameVisible() }
        .onReceive(NotificationCenter.default.publisher(for: .claudeActivity)) { _ in
            model.noteActivity(visible: visibility.isOpen)
        }
        .onChange(of: visibility.isOpen) { _, open in if open { model.becameVisible() } }
    }

    // MARK: - Header

    private var dayHeader: some View {
        HStack(spacing: 6) {
            stepButton("chevron.left", days: -1, enabled: true)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { pickingDate.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(dayLabel)
                        .font(Theme.label(11, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .rotationEffect(.degrees(pickingDate ? 180 : 0))
                }
                .foregroundStyle(.primary)
                // Fills the gap between the arrows so the whole middle of the
                // header is the hit target, not just the few words of the label.
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to a date")

            stepButton("chevron.right", days: 1, enabled: !model.isOnToday)

            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isLoading ? 360 : 0))
                    .animation(model.isLoading
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default, value: model.isLoading)
            }
            .buttonStyle(.borderless)
            .disabled(model.isLoading)
            .help("Rescan transcripts")

            Button {
                model.copyToPasteboard()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(model.day?.isEmpty ?? true)
            .help("Copy this day")
        }
        .font(.system(size: 11))
    }

    /// Drawn inline rather than in a compact picker's own calendar window: the
    /// popover is `.transient`, so the first click inside a separate window
    /// would dismiss the whole panel before the date ever landed.
    private var calendar: some View {
        Panel {
            MonthGrid(selected: model.date, activeDays: model.activeDays) { picked in
                model.jump(to: picked)
                // Collapse on choose. Leaving it open would push the day it was
                // opened to see off the bottom of the panel.
                withAnimation(.easeOut(duration: 0.15)) { pickingDate = false }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func stepButton(_ symbol: String, days: Int, enabled: Bool) -> some View {
        Button { model.step(days) } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
    }

    private var dayLabel: String {
        if model.isOnToday { return "Today" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInYesterday(model.date)
            ? "'Yesterday'" : "EEEE d MMMM"
        return formatter.string(from: model.date)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let day = model.day {
            if day.isEmpty {
                Panel {
                    Text("No sessions on this day.")
                        .font(Theme.label(11, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(day.groups) { group in repoPanel(group) }
                }
            }
        } else {
            Panel {
                Text("Reading transcripts…")
                    .font(Theme.label(11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func repoPanel(_ group: RepoGroup) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(group.repo)
                        .font(Theme.label(11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    // One repo at a time is the common case: a standup note is
                    // about the thing you worked on, not about every checkout
                    // you happened to touch.
                    Button {
                        model.copyToPasteboard(group)
                        copiedRepo = group.repo
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            if copiedRepo == group.repo { copiedRepo = nil }
                        }
                    } label: {
                        Image(systemName: copiedRepo == group.repo ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy \(group.repo)")
                }

                VStack(alignment: .leading, spacing: 7) {
                    // Positional identity: `sessionID` is empty for transcripts
                    // that never recorded one, and two of those in one repo
                    // would collide.
                    ForEach(Array(group.sessions.enumerated()), id: \.offset) { _, session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: WorkLogSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            bullet("•", session.title, size: 11, color: .primary)

            // Sub-bullets exist only for sessions that tracked todos — which are
            // exactly the long, multi-task ones worth breaking apart.
            ForEach(Array(session.todos.prefix(todoLimit).enumerated()), id: \.offset) { _, todo in
                bullet("–", todo, size: 10, color: .secondary)
                    .padding(.leading, 12)
            }
            if session.todos.count > todoLimit {
                Text("+\(session.todos.count - todoLimit) more")
                    .font(Theme.label(9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 24)
            }
        }
    }

    private func bullet(_ marker: String, _ text: String,
                        size: CGFloat, color: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(marker)
                .font(Theme.label(size, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(Theme.label(size, weight: .regular))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
