import Foundation

/// One usage limit row, normalized from whatever shape the API returned.
struct LimitBucket: Codable, Equatable, Identifiable {
    var id: String { key }

    /// Stable identifier: the `kind` from `limits[]` ("session", "weekly_all", ...)
    /// or the top-level bucket name ("five_hour") when falling back.
    let key: String
    let displayName: String
    /// Always 0...100.
    let percent: Double
    let resetsAt: Date?

    /// True for the 5-hour rolling session limit — the menu bar's top bar.
    var isSession: Bool { key == "session" || key == "five_hour" }
    /// True for any 7-day limit, whichever variant the plan exposes.
    var isWeekly: Bool { key.hasPrefix("weekly") || key.hasPrefix("seven_day") }
}

/// A complete reading of every limit the account exposes.
struct UsageSnapshot: Codable, Equatable {
    let buckets: [LimitBucket]
    let fetchedAt: Date

    /// Considered stale once it predates the poll interval by a comfortable margin.
    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > 20 * 60
    }

    var session: LimitBucket? { buckets.first(where: \.isSession) }

    /// The plan may expose several weekly buckets (all / opus / sonnet).
    /// The menu bar shows the most-consumed one, since that's what will bite first.
    var weekly: LimitBucket? {
        buckets.filter(\.isWeekly).max(by: { $0.percent < $1.percent })
    }

    /// The limit the menu bar renders.
    ///
    /// The session window is what the user asked to see. Plans that don't expose
    /// one fall back to the most-consumed weekly bucket rather than showing
    /// nothing. Returning the *bucket* (not a number) means the menu bar derives
    /// its label and its colour from a single source, so the two can't disagree.
    var menuBarBucket: LimitBucket? { session ?? weekly }
}

/// Severity thresholds, shared by the menu bar, popover, and notifications so
/// they can never disagree about what "high" means.
enum Urgency {
    case normal, warning, critical

    init(percent: Double) {
        switch percent {
        case ..<75: self = .normal
        case ..<90: self = .warning
        default: self = .critical
        }
    }

    /// The single threshold the 90% notification fires on.
    static let notifyThreshold: Double = 90
}
