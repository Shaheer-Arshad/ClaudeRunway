import Foundation

/// Errors shared by both transports.
enum UsageError: Error, LocalizedError, Equatable {
    case noSessionKey
    /// The session key was rejected or expired — the user must paste a new one.
    case sessionExpired
    /// The Claude Code OAuth token was rejected.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case transport(String)
    case undecodable

    var errorDescription: String? {
        switch self {
        case .noSessionKey: return "No session key — add one for live updates"
        case .sessionExpired: return "Session key expired — paste a new one"
        case .unauthorized: return "Claude Code sign-in expired"
        case .rateLimited: return "Rate limited by Anthropic"
        case .http(let code): return "Server returned HTTP \(code)"
        case .transport(let msg): return msg
        case .undecodable: return "Unexpected response format"
        }
    }
}

/// Turns a usage response into a snapshot.
///
/// Both the claude.ai web endpoint and the OAuth endpoint return byte-identical
/// structures, so this is deliberately transport-agnostic and shared by both.
enum UsageParser {

    static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.undecodable
        }
        return try parse(root: root, fetchedAt: fetchedAt)
    }

    static func parse(root: [String: Any], fetchedAt: Date) throws -> UsageSnapshot {
        // Preferred path: the `limits` array is plan-aware and self-describing,
        // so we don't have to guess which buckets this account has.
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            let buckets = limits.compactMap(bucketFromLimitsEntry)
            if !buckets.isEmpty {
                return UsageSnapshot(buckets: buckets, fetchedAt: fetchedAt)
            }
        }

        // Fallback: named top-level buckets, for if `limits` ever disappears.
        let buckets = fallbackKeys.compactMap { key -> LimitBucket? in
            guard let obj = root[key] as? [String: Any] else { return nil }
            guard let percent = percentValue(obj["utilization"] ?? obj["used_percentage"]) else { return nil }
            return LimitBucket(key: key,
                               displayName: label(forKind: key),
                               percent: percent,
                               resetsAt: date(from: obj["resets_at"]))
        }

        guard !buckets.isEmpty else { throw UsageError.undecodable }
        return UsageSnapshot(buckets: buckets, fetchedAt: fetchedAt)
    }

    /// Order matters — it's the display order when falling back.
    private static let fallbackKeys = [
        "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included",
    ]

    private static func bucketFromLimitsEntry(_ entry: [String: Any]) -> LimitBucket? {
        let kind = (entry["kind"] as? String) ?? (entry["group"] as? String)
        guard let kind, let percent = percentValue(entry["percent"] ?? entry["utilization"]) else {
            return nil
        }
        return LimitBucket(key: kind,
                           displayName: label(forKind: kind),
                           percent: percent,
                           resetsAt: date(from: entry["resets_at"]))
    }

    /// Values have been observed as 0–100. Guard against a 0–1 fraction in case
    /// the representation ever differs between fields.
    static func percentValue(_ raw: Any?) -> Double? {
        let value: Double
        switch raw {
        case let d as Double: value = d
        case let i as Int: value = Double(i)
        case let s as String: guard let d = Double(s) else { return nil }; value = d
        default: return nil
        }
        guard value.isFinite, value >= 0 else { return nil }
        let normalized = value <= 1 ? value * 100 : value
        return min(normalized, 100)
    }

    static func date(from raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        // Timestamps carry fractional seconds ("...59.652290+00:00"), which the
        // plain ISO8601 formatter rejects, so try both.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Human labels. Unknown kinds are title-cased rather than dropped, so a
    /// new server-side bucket still shows up instead of silently vanishing.
    static func label(forKind kind: String) -> String {
        switch kind {
        case "session", "five_hour": return "Session (5h)"
        case "weekly_all", "seven_day": return "Weekly (all models)"
        case "weekly_opus", "seven_day_opus": return "Weekly (Opus)"
        case "weekly_sonnet", "seven_day_sonnet": return "Weekly (Sonnet)"
        case "seven_day_overage_included": return "Weekly (Fable)"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The observed 429 carried `retry-after: 0`, which would mean "hammer me
    /// immediately" if taken at face value. Only trust positive, sane values.
    static func retryAfter(from http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0, seconds <= 3600
        else { return nil }
        return seconds
    }
}
