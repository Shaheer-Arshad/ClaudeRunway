import Foundation

/// Which transport the app should use, and how hard it may poll.
///
/// The two endpoints have wildly different limits, so the cadence is a property
/// of the transport rather than a global constant:
///   - web:   5 requests at 2s spacing all returned 200 → 60s polling is easy
///   - oauth: a request 5 minutes after the previous one still 429'd
enum Transport: Equatable {
    case web
    case oauth

    /// Unattended poll cadence.
    var pollInterval: TimeInterval {
        switch self {
        case .web: return 60
        case .oauth: return 15 * 60
        }
    }

    /// Hard floor between any two requests, bypassed only by the Refresh button.
    var minInterval: TimeInterval {
        switch self {
        case .web: return 15
        case .oauth: return 10 * 60
        }
    }

    var label: String {
        switch self {
        case .web: return "live"
        case .oauth: return "slow mode"
        }
    }
}

/// The decision of whether a refresh may proceed, isolated from the side effects
/// so it can be tested directly.
enum RefreshGate {

    /// Web whenever a session key is present and hasn't been rejected; otherwise
    /// fall back to the always-available (but slow) OAuth path.
    static func transport(hasSessionKey: Bool, sessionExpired: Bool) -> Transport {
        (hasSessionKey && !sessionExpired) ? .web : .oauth
    }

    static func shouldFetch(now: Date,
                            lastAttempt: Date?,
                            throttledUntil: Date?,
                            minInterval: TimeInterval,
                            force: Bool) -> Bool {
        // The manual Refresh button is the one deliberate override.
        if force { return true }

        // Backing off after a 429.
        if let until = throttledUntil, now < until { return false }

        // Minimum spacing between requests. `lastAttempt` is persisted, so
        // restarts don't bypass this.
        if let last = lastAttempt, now.timeIntervalSince(last) < minInterval { return false }

        return true
    }

    /// 5 → 10 → 20 → 40 → capped at 60 minutes.
    ///
    /// Only ever reached via the OAuth path in practice; the web endpoint has
    /// not been observed to rate limit at all.
    static func nextBackoff(current: TimeInterval) -> TimeInterval {
        current == 0 ? 5 * 60 : min(current * 2, 60 * 60)
    }
}
