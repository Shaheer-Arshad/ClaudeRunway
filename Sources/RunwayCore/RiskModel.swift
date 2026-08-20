import Foundation

/// How worried to be about a limit, on a 0…1 scale.
///
/// A raw percentage is a poor signal on its own: 60% used is alarming an hour
/// into a five-hour window and unremarkable four hours in, because the window is
/// about to reset. So risk combines three independent views and takes the worst:
///
///   - **absolute**   — how close to the ceiling
///   - **projection** — where the current burn rate lands by reset time
///   - **pacing**     — how far ahead of linear consumption you are right now
///
/// `pacePercent` is what the UI marks on the gauge: the position you'd be at if
/// you consumed evenly across the window.
struct UsageRisk: Equatable {
    /// 0…1, the worst of the three signals.
    let value: Double
    /// Fraction of the reset window elapsed, 0…1.
    let elapsed: Double
    /// Where even consumption would put you right now, 0…100.
    let pacePercent: Double
    /// Extrapolated end-of-window usage; nil very early in a window, when the
    /// estimate is meaningless.
    let projectedPercent: Double?

    /// Positive means burning faster than the window can absorb.
    var paceDelta: Double { projectedPercent.map { $0 - 100 } ?? 0 }
}

enum RiskModel {

    /// Window lengths are fixed by the plan, not returned by the API, so they're
    /// derived from the bucket kind.
    static func windowLength(for bucket: LimitBucket) -> TimeInterval? {
        if bucket.isSession { return 5 * 3600 }
        if bucket.isWeekly { return 7 * 24 * 3600 }
        return nil
    }

    /// How far through the reset window we are.
    static func elapsedFraction(for bucket: LimitBucket, now: Date = Date()) -> Double? {
        guard let length = windowLength(for: bucket), let resetsAt = bucket.resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return clamp((length - remaining) / length, 0, 1)
    }

    static func risk(for bucket: LimitBucket, now: Date = Date()) -> UsageRisk {
        risk(percent: bucket.percent, elapsed: elapsedFraction(for: bucket, now: now))
    }

    static func risk(percent: Double, elapsed: Double?) -> UsageRisk {
        // Without a window we can only judge the level itself.
        guard let elapsed, elapsed > 0.001 else {
            return UsageRisk(value: smoothstep(50, 100, percent),
                             elapsed: elapsed ?? 0,
                             pacePercent: 0,
                             projectedPercent: nil)
        }

        let pace = elapsed * 100
        let projected = percent / elapsed

        // Early in a window a single burst extrapolates to nonsense, so the
        // projection earns weight as evidence accumulates. Confidence is near
        // zero in the first moments and effectively full by a third of the way
        // in — by then the trend is real and a warning is still actionable.
        let confidence = 0.05 + 0.95 * smoothstep(0, 0.35, elapsed)

        // Heavy usage late in a window is fine — it resets shortly. Only let the
        // absolute level matter when the projection agrees it's a problem.
        let absolute = smoothstep(55, 105, percent) * smoothstep(70, 100, projected)
        let projectionRisk = smoothstep(85, 125, projected) * confidence
        let pacingRisk = smoothstep(0, 20, percent - pace) * confidence

        return UsageRisk(value: clamp(max(absolute, max(projectionRisk, pacingRisk)), 0, 1),
                         elapsed: elapsed,
                         pacePercent: pace,
                         projectedPercent: min(projected, 999))
    }

    // MARK: - Presentation

    /// Below this, surfaces stay monochrome.
    ///
    /// Colour in the menu bar should mean "look at me", not "everything is
    /// fine" — a permanently green icon is just chrome the eye stops reading.
    static let tintThreshold = 0.30

    static func shouldTint(_ risk: Double) -> Bool { risk >= tintThreshold }

    // MARK: - Math

    /// Hermite ease between two edges. Gives the gauge a continuous colour ramp
    /// instead of visible steps at threshold boundaries.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}
