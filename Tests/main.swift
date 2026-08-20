import Foundation

/// Verbatim excerpt of a real HTTP 200 captured from /api/oauth/usage, trimmed
/// to the fields we consume. The nulls are kept deliberately — they are the
/// normal case for plans without Opus/Sonnet sub-limits.
let liveResponse = """
{
  "five_hour": {"limit_dollars": null, "remaining_dollars": null,
                "resets_at": "2026-07-29T22:59:59.652290+00:00",
                "used_dollars": null, "utilization": 11},
  "seven_day": {"limit_dollars": null, "remaining_dollars": null,
                "resets_at": "2026-08-05T08:59:59.652312+00:00",
                "used_dollars": null, "utilization": 7},
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [
    {"group": "session", "is_active": true, "kind": "session", "percent": 11,
     "resets_at": "2026-07-29T22:59:59.652290+00:00", "scope": null, "severity": "normal"},
    {"group": "weekly", "is_active": false, "kind": "weekly_all", "percent": 7,
     "resets_at": "2026-08-05T08:59:59.652312+00:00", "scope": null, "severity": "normal"}
  ]
}
""".data(using: .utf8)!

T.test("parses the live response via the limits array") {
    let snap = try UsageParser.parse(liveResponse, fetchedAt: Date())
    T.equal(snap.buckets.count, 2, "null buckets must not become rows")
    T.equal(snap.session?.percent, 11, "session percent")
    T.equal(snap.session?.displayName, "Session (5h)", "session label")
    T.equal(snap.weekly?.percent, 7, "weekly percent")
    T.equal(snap.weekly?.displayName, "Weekly (all models)", "weekly label")
    T.equal(snap.menuBarBucket?.key, "session", "the menu bar shows the session limit")
    T.expect(snap.session?.resetsAt != nil, "fractional-second timestamps must parse")
}

T.test("falls back to named buckets when limits array is missing") {
    let json = """
    {"five_hour": {"utilization": 42, "resets_at": "2026-07-29T22:59:59.652290+00:00"},
     "seven_day": {"utilization": 88, "resets_at": null},
     "seven_day_opus": null}
    """.data(using: .utf8)!
    let snap = try UsageParser.parse(json, fetchedAt: Date())
    T.equal(snap.buckets.map(\.key), ["five_hour", "seven_day"], "fallback keys and order")
    T.equal(snap.menuBarBucket?.percent, 42, "the menu bar tracks the session limit, not the larger weekly one")
    T.expect(snap.buckets[1].resetsAt == nil, "a null resets_at must not crash")
}

T.test("unknown bucket kinds are shown, not dropped") {
    let json = #"{"limits": [{"kind": "monthly_experimental", "percent": 5}]}"#.data(using: .utf8)!
    let snap = try UsageParser.parse(json, fetchedAt: Date())
    T.equal(snap.buckets.first?.displayName, "Monthly Experimental", "title-cased fallback label")
}

T.test("weekly picks the most-consumed variant") {
    let json = """
    {"limits": [
      {"kind": "weekly_all", "percent": 20},
      {"kind": "weekly_opus", "percent": 71},
      {"kind": "session", "percent": 5}
    ]}
    """.data(using: .utf8)!
    let snap = try UsageParser.parse(json, fetchedAt: Date())
    T.equal(snap.weekly?.key, "weekly_opus", "highest weekly wins")
    T.equal(snap.menuBarBucket?.key, "session", "menu bar still shows session, even when a weekly bucket is higher")
}

T.test("percent normalization") {
    T.equal(UsageParser.percentValue(11), 11, "0-100 ints pass through")
    T.equal(UsageParser.percentValue(7.5), 7.5, "doubles pass through")
    T.equal(UsageParser.percentValue(0.62), 62, "a 0-1 fraction is scaled up")
    T.equal(UsageParser.percentValue(150), 100, "clamped to 100")
    T.equal(UsageParser.percentValue("33"), 33, "numeric strings parse")
    T.expect(UsageParser.percentValue(nil) == nil, "nil rejected")
    T.expect(UsageParser.percentValue(NSNull()) == nil, "NSNull rejected")
    T.expect(UsageParser.percentValue(-5) == nil, "negatives rejected")
}

T.test("empty or garbage responses throw") {
    T.throwsError("empty object") { _ = try UsageParser.parse(Data("{}".utf8), fetchedAt: Date()) }
    T.throwsError("non-JSON") { _ = try UsageParser.parse(Data("not json".utf8), fetchedAt: Date()) }
    T.throwsError("all-null buckets is a failure, not an empty snapshot") {
        _ = try UsageParser.parse(Data(#"{"seven_day_opus": null, "seven_day_sonnet": null}"#.utf8), fetchedAt: Date())
    }
}

// The live 429 carried `retry-after: 0`; obeying that literally would mean
// retrying instantly against an endpoint that had just throttled us.
T.test("zero and absurd Retry-After values are ignored") {
    func header(_ value: String?) -> HTTPURLResponse {
        HTTPURLResponse(url: UsageAPI.endpoint, statusCode: 429, httpVersion: nil,
                        headerFields: value.map { ["Retry-After": $0] })!
    }
    T.expect(UsageParser.retryAfter(from: header("0")) == nil, "zero ignored")
    T.expect(UsageParser.retryAfter(from: header("-30")) == nil, "negative ignored")
    T.expect(UsageParser.retryAfter(from: header("99999")) == nil, "absurdly large ignored")
    T.expect(UsageParser.retryAfter(from: header(nil)) == nil, "absent header")
    T.equal(UsageParser.retryAfter(from: header("120")), 120, "sane value honored")
}

T.test("urgency thresholds") {
    T.expect(Urgency(percent: 0) == .normal, "0 is normal")
    T.expect(Urgency(percent: 74.9) == .normal, "just under warning")
    T.expect(Urgency(percent: 75) == .warning, "warning boundary")
    T.expect(Urgency(percent: 89.9) == .warning, "just under critical")
    T.expect(Urgency(percent: 90) == .critical, "critical boundary matches notify threshold")
}

T.test("staleness") {
    T.expect(!UsageSnapshot(buckets: [], fetchedAt: Date()).isStale(), "fresh snapshot")
    T.expect(UsageSnapshot(buckets: [], fetchedAt: Date().addingTimeInterval(-21 * 60)).isStale(),
             "21-minute-old snapshot is stale")
}

// The endpoint tolerates roughly one request per five minutes — observed as
// 200 / 429 (+75s) / 200 (+6min). These are the rules that keep us inside that.
T.test("refresh gate spacing") {
    let now = Date()
    let fiveMin: TimeInterval = 300

    T.expect(RefreshGate.shouldFetch(now: now, lastAttempt: nil, throttledUntil: nil,
                                     minInterval: fiveMin, force: false),
             "first ever fetch is allowed")

    T.expect(!RefreshGate.shouldFetch(now: now, lastAttempt: now.addingTimeInterval(-60),
                                      throttledUntil: nil, minInterval: fiveMin, force: false),
             "a fetch 1 minute ago blocks the next one")

    T.expect(RefreshGate.shouldFetch(now: now, lastAttempt: now.addingTimeInterval(-301),
                                     throttledUntil: nil, minInterval: fiveMin, force: false),
             "just past the interval is allowed")

    T.expect(!RefreshGate.shouldFetch(now: now, lastAttempt: nil,
                                      throttledUntil: now.addingTimeInterval(600),
                                      minInterval: fiveMin, force: false),
             "backoff blocks even with no recent attempt")

    T.expect(RefreshGate.shouldFetch(now: now, lastAttempt: now,
                                     throttledUntil: now.addingTimeInterval(600),
                                     minInterval: fiveMin, force: false) == false,
             "backoff and spacing both block")

    T.expect(RefreshGate.shouldFetch(now: now, lastAttempt: now,
                                     throttledUntil: now.addingTimeInterval(600),
                                     minInterval: fiveMin, force: true),
             "the manual Refresh button overrides everything")
}

T.test("backoff progression caps at an hour") {
    var b: TimeInterval = 0
    b = RefreshGate.nextBackoff(current: b); T.equal(b, 300, "first backoff is 5 min")
    b = RefreshGate.nextBackoff(current: b); T.equal(b, 600, "then 10")
    b = RefreshGate.nextBackoff(current: b); T.equal(b, 1200, "then 20")
    b = RefreshGate.nextBackoff(current: b); T.equal(b, 2400, "then 40")
    b = RefreshGate.nextBackoff(current: b); T.equal(b, 3600, "capped at 60")
    b = RefreshGate.nextBackoff(current: b); T.equal(b, 3600, "stays capped")
}

T.test("notifies once per limit per reset window") {
    let suite = "test.notifier.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    var sent: [String] = []
    let notifier = Notifier(defaults: defaults, deliver: { title, _ in sent.append(title) })

    let window = Date().addingTimeInterval(3600)
    func snapshot(_ percent: Double, resetsAt: Date) -> UsageSnapshot {
        UsageSnapshot(buckets: [LimitBucket(key: "session", displayName: "Session (5h)",
                                            percent: percent, resetsAt: resetsAt)],
                      fetchedAt: Date())
    }

    notifier.evaluate(snapshot(45, resetsAt: window))
    T.equal(sent.count, 0, "no notification below the threshold")

    notifier.evaluate(snapshot(91, resetsAt: window))
    T.equal(sent.count, 1, "crossing 90% notifies")

    // The 15-minute poll will keep seeing the same high number.
    notifier.evaluate(snapshot(93, resetsAt: window))
    T.equal(sent.count, 1, "still-high usage in the same window does not re-notify")

    // A new window means resets_at changed.
    notifier.evaluate(snapshot(95, resetsAt: window.addingTimeInterval(18000)))
    T.equal(sent.count, 2, "a new reset window notifies again")

    defaults.removePersistentDomain(forName: suite)
}

T.test("dedupe keys do not accumulate across windows") {
    let suite = "test.notifier.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let notifier = Notifier(defaults: defaults, deliver: { _, _ in })

    for i in 0..<5 {
        let reset = Date().addingTimeInterval(Double(i) * 18000)
        notifier.evaluate(UsageSnapshot(
            buckets: [LimitBucket(key: "session", displayName: "Session (5h)",
                                  percent: 95, resetsAt: reset)],
            fetchedAt: Date()))
    }

    let stored = defaults.stringArray(forKey: "notifiedWindows") ?? []
    T.equal(stored.count, 1, "only keys for currently-live windows are retained")

    defaults.removePersistentDomain(forName: suite)
}

// MARK: - Transport selection

T.test("transport selection prefers web, falls back to oauth") {
    T.expect(RefreshGate.transport(hasSessionKey: true, sessionExpired: false) == .web,
             "a valid session key means live updates")
    T.expect(RefreshGate.transport(hasSessionKey: false, sessionExpired: false) == .oauth,
             "no session key falls back to the slow path")
    T.expect(RefreshGate.transport(hasSessionKey: true, sessionExpired: true) == .oauth,
             "an expired key must not keep being retried as web")
}

// Measured: the web endpoint served 5 requests at 2s spacing without complaint,
// while the OAuth endpoint 429'd at 5-minute spacing.
T.test("each transport carries its own cadence") {
    T.equal(Transport.web.pollInterval, 60, "web polls every minute")
    T.equal(Transport.oauth.pollInterval, 900, "oauth polls every 15 minutes")
    T.expect(Transport.web.minInterval < Transport.oauth.minInterval,
             "the web floor is far looser than the oauth one")
    T.equal(Transport.oauth.minInterval, 600, "oauth keeps a 10-minute floor")
}

// MARK: - Session key handling

T.test("session key normalization accepts what users actually paste") {
    let key = "sk-ant-sid02-" + String(repeating: "x", count: 60)

    T.equal(SessionKeyStore.normalize(key), key, "a bare key is unchanged")
    T.equal(SessionKeyStore.normalize("  \(key)\n"), key, "surrounding whitespace is trimmed")
    T.equal(SessionKeyStore.normalize("sessionKey=\(key)"), key, "the cookie name is stripped")
    T.equal(SessionKeyStore.normalize("foo=1; sessionKey=\(key); bar=2"), key,
            "the key is extracted from a full cookie header")
}

T.test("obviously wrong session keys are rejected before any network call") {
    let key = "sk-ant-sid02-" + String(repeating: "x", count: 60)
    T.expect(SessionKeyStore.looksValid(key), "a real-shaped key passes")
    T.expect(SessionKeyStore.looksValid("sessionKey=\(key)"), "cookie form passes")
    T.expect(!SessionKeyStore.looksValid(""), "empty rejected")
    T.expect(!SessionKeyStore.looksValid("sk-ant-sid02-short"), "too short rejected")
    T.expect(!SessionKeyStore.looksValid("sk-ant-api03-" + String(repeating: "x", count: 60)),
             "an API key is not a session key")
}

// MARK: - Risk model
//
// The whole point of the risk model is that a bare percentage is a bad signal:
// the same number means different things at different points in the window.

T.test("identical usage is risky early and calm late") {
    let early = RiskModel.risk(percent: 60, elapsed: 0.20)
    let late = RiskModel.risk(percent: 60, elapsed: 0.95)

    T.expect(early.value > late.value,
             "60% a fifth of the way in is worse than 60% near reset")
    T.expect(late.value < 0.30, "60% with the window nearly over is not a concern")
    T.expect(early.value > 0.55, "60% burned in 20% of the window is serious")
}

T.test("projection extrapolates the burn rate") {
    let r = RiskModel.risk(percent: 50, elapsed: 0.25)
    T.equal(r.projectedPercent.map { Int($0) }, 200, "50% at quarter-elapsed projects to 200%")
    T.equal(r.pacePercent, 25, "even consumption would be at 25%")
    T.expect(r.value > 0.5, "a 2x overshoot is high risk")
}

T.test("staying on pace stays calm even at high absolute usage") {
    let r = RiskModel.risk(percent: 80, elapsed: 0.80)
    T.equal(r.projectedPercent.map { Int($0) }, 100, "exactly on track to finish at 100%")
    T.expect(r.value < 0.65, "tracking linearly is not an emergency")
    T.expect(abs(r.pacePercent - 80) < 0.001, "pace marker sits on the fill")
}

T.test("early spikes are damped by low confidence") {
    // 5% in the first 1% of a window projects to 500%, but one burst proves little.
    let veryEarly = RiskModel.risk(percent: 5, elapsed: 0.01)
    let sustained = RiskModel.risk(percent: 50, elapsed: 0.10)
    T.expect(veryEarly.value < sustained.value,
             "a single early burst must not scream louder than a sustained trend")
}

T.test("risk without a known window falls back to the level alone") {
    let r = RiskModel.risk(percent: 95, elapsed: nil)
    T.expect(r.value > 0.9, "95% is high risk regardless of timing")
    T.expect(r.projectedPercent == nil, "no projection without a window")
    T.equal(r.pacePercent, 0, "no pace marker to draw")
}

T.test("risk is bounded and monotonic in usage") {
    var previous = -1.0
    for pct in stride(from: 0.0, through: 100.0, by: 10.0) {
        let v = RiskModel.risk(percent: pct, elapsed: 0.5).value
        T.expect(v >= 0 && v <= 1, "risk stays in 0...1 at \(Int(pct))%")
        T.expect(v >= previous - 0.0001, "risk never decreases as usage rises (\(Int(pct))%)")
        previous = v
    }
}

T.test("window lengths come from the bucket kind") {
    let session = LimitBucket(key: "session", displayName: "s", percent: 0, resetsAt: nil)
    let weekly = LimitBucket(key: "weekly_all", displayName: "w", percent: 0, resetsAt: nil)
    let unknown = LimitBucket(key: "mystery", displayName: "m", percent: 0, resetsAt: nil)

    T.equal(RiskModel.windowLength(for: session), 5 * 3600, "session is 5 hours")
    T.equal(RiskModel.windowLength(for: weekly), 7 * 24 * 3600, "weekly is 7 days")
    T.expect(RiskModel.windowLength(for: unknown) == nil, "unknown kinds have no window")
}

T.test("elapsed fraction derives from the reset timestamp") {
    let now = Date()
    // Half of a five-hour window remaining.
    let bucket = LimitBucket(key: "session", displayName: "s", percent: 0,
                             resetsAt: now.addingTimeInterval(2.5 * 3600))
    let elapsed = RiskModel.elapsedFraction(for: bucket, now: now)
    T.expect(elapsed != nil && abs(elapsed! - 0.5) < 0.01, "halfway through the window")

    // A stale snapshot whose window already rolled over must clamp, not go negative.
    let past = LimitBucket(key: "session", displayName: "s", percent: 0,
                           resetsAt: now.addingTimeInterval(-3600))
    T.equal(RiskModel.elapsedFraction(for: past, now: now), 1, "clamped at fully elapsed")
}

// MARK: - Menu bar selection
//
// The menu bar shows one bucket and colours the mark from that same bucket, so
// the number and the colour can never contradict each other.

T.test("menu bar prefers the session bucket") {
    let json = """
    {"limits": [
      {"kind": "weekly_all", "percent": 90},
      {"kind": "session", "percent": 12}
    ]}
    """.data(using: .utf8)!
    let snap = try UsageParser.parse(json, fetchedAt: Date())
    T.equal(snap.menuBarBucket?.key, "session", "session wins even when weekly is far higher")
    T.equal(snap.menuBarBucket?.percent, 12, "and the percentage comes from it")
}

T.test("menu bar falls back to weekly when a plan has no session bucket") {
    let json = """
    {"limits": [
      {"kind": "weekly_all", "percent": 30},
      {"kind": "weekly_opus", "percent": 64}
    ]}
    """.data(using: .utf8)!
    let snap = try UsageParser.parse(json, fetchedAt: Date())
    T.equal(snap.menuBarBucket?.key, "weekly_opus", "the most-consumed weekly bucket stands in")
}

T.test("menu bar has nothing to show for an empty snapshot") {
    T.expect(UsageSnapshot(buckets: [], fetchedAt: Date()).menuBarBucket == nil,
             "no buckets means the item renders its dash state")
}

T.test("tint threshold keeps low risk monochrome") {
    T.expect(!RiskModel.shouldTint(0), "idle is not coloured")
    T.expect(!RiskModel.shouldTint(0.29), "just below the threshold stays monochrome")
    T.expect(RiskModel.shouldTint(0.30), "the threshold itself tints")
    T.expect(RiskModel.shouldTint(1.0), "maximum risk tints")
}

runWorkLogTests()
runHistoryTests()
runCredentialTests()

T.summarize()
