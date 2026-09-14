import SwiftUI
/// A month of days, drawn rather than borrowed.
///
/// `DatePicker(.graphical)` was the obvious choice and is the wrong one here:
/// it wraps `NSDatePicker`, which is pinned at 138×148pt and ignores any frame
/// given to it — measured, not assumed. In a 260pt panel that leaves a small
/// system-styled island adrift in the middle, in the system font and the system
/// accent, next to type and colour this app sets everywhere else.
struct MonthGrid: View {
    let selected: Date
    /// `yyyy-MM-dd` keys — the same shape `WorkLogStore` groups by — for every
    /// day that has at least one session, so the grid can dot them.
    let activeDays: Set<String>
    let onPick: (Date) -> Void

    /// The month on screen, which is not the selected month once you page away
    /// from it — you can look at March without leaving the day you were on.
    @State private var month: Date

    private let calendar = Calendar.current

    init(selected: Date, activeDays: Set<String>, onPick: @escaping (Date) -> Void) {
        self.selected = selected
        self.activeDays = activeDays
        self.onPick = onPick
        _month = State(initialValue: selected)
    }

    var body: some View {
        VStack(spacing: 6) {
            monthHeader
            weekdayHeader
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    // Positional identity: blank padding cells are all equal to
                    // each other, so they cannot identify themselves.
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
            }
        }
        .onChange(of: selected) { _, new in month = new }
    }

    // MARK: - Header

    private var monthHeader: some View {
        HStack(spacing: 0) {
            pageButton("chevron.left", by: -1, enabled: true)
            Text(monthLabel)
                .font(Theme.label(11, weight: .semibold))
                .frame(maxWidth: .infinity)
            pageButton("chevron.right", by: 1, enabled: !isCurrentMonth)
        }
        .padding(.bottom, 2)
    }

    private func pageButton(_ symbol: String, by months: Int, enabled: Bool) -> some View {
        Button {
            guard let moved = calendar.date(byAdding: .month, value: months, to: month) else { return }
            month = moved
        } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.25))
        .disabled(!enabled)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(Theme.label(9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Days

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let isSelected = calendar.isDate(day, inSameDayAs: selected)
            let isFuture = calendar.startOfDay(for: day) > calendar.startOfDay(for: Date())
            let hasSession = activeDays.contains(WorkLogStore.dayKey(day, timeZone: .current))

            Button { onPick(day) } label: {
                VStack(spacing: 1) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(Theme.label(10.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(dayColor(isSelected: isSelected,
                                                  isToday: calendar.isDateInToday(day),
                                                  isFuture: isFuture))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if isSelected {
                                Circle().fill(Theme.accent).frame(width: 22, height: 22)
                            }
                        }

                    // A day with work, marked underneath its number rather than
                    // on it: the number stays legible and the selected day's
                    // white-on-accent circle isn't fighting a second dot for
                    // the same few pixels.
                    Circle()
                        .fill(hasSession && !isFuture ? dotColor(isSelected: isSelected) : .clear)
                        .frame(width: 3, height: 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFuture)
        } else {
            // Padding for the days either side of the month. Kept as blanks
            // rather than the neighbouring months' numbers: those are not
            // reachable from this grid, and drawing them invites the click.
            Color.clear.frame(maxWidth: .infinity, minHeight: 25)
        }
    }

    private func dotColor(isSelected: Bool) -> Color {
        isSelected ? .white : Theme.accent
    }

    private func dayColor(isSelected: Bool, isToday: Bool, isFuture: Bool) -> Color {
        if isSelected { return .white }
        if isFuture { return .secondary.opacity(0.3) }
        if isToday { return Theme.accent }
        return .primary
    }

    // MARK: - Layout

    private var isCurrentMonth: Bool {
        calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: month)
    }

    /// Weekday initials in the user's own week order — a locale starting its
    /// week on Monday must not be handed a Sunday-first grid.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    /// The month as six rows of seven, `nil` where a cell falls outside it.
    ///
    /// Always six, even when five would hold the month: a grid that changes
    /// height as you page resizes the popover under the cursor, and the sixth
    /// row is needed often enough (any 31-day month starting late in the week)
    /// that reserving it costs less than the jump.
    private var weeks: [[Date?]] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return [] }

        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        cells += range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
        cells += Array(repeating: nil, count: 42 - cells.count)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}
