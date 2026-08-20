import Combine
import Foundation
import os

/// Owns *when* and *how* the app fetches. Views never fetch; they observe.
///
/// Two transports with very different characteristics:
///   - `.web`   — claude.ai session key, effectively unthrottled, polls at 60s
///   - `.oauth` — Claude Code's keychain token, ~1 request per 6–7 min
///
/// Web is preferred; OAuth is the automatic fallback when there's no session key
/// or it has expired, so the app degrades to slow updates instead of breaking.
@MainActor
final class UsageController: ObservableObject {

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    /// Set when we're deliberately holding off after a 429.
    ///
    /// Tracked per transport: the two endpoints have entirely separate quotas,
    /// so a 429 from the OAuth path must not suppress the web path (or vice
    /// versa) once we switch between them.
    @Published private(set) var throttledUntil: Date?
    private var throttles: [Transport: Date] = [:]
    private var backoffs: [Transport: TimeInterval] = [:]
    /// Last 24h of readings, for the sparkline.
    @Published private(set) var recentSeries: [HistoryStore.Sample] = []
    /// True once the session key has been rejected — the UI prompts for a new one.
    @Published private(set) var sessionExpired = false
    @Published private(set) var hasSessionKey = SessionKeyStore.load() != nil

    var transport: Transport {
        RefreshGate.transport(hasSessionKey: hasSessionKey, sessionExpired: sessionExpired)
    }

    private let history: HistoryStore
    private let notifier: Notifier
    private let webFetcher: () async throws -> UsageSnapshot
    private let oauthFetcher: () async throws -> UsageSnapshot

    private var lastAttempt: Date?
    private var lastSuccess: Date?
    private var ticker: Timer?
    /// Rate-limits how often a skipped fetch is logged, so a 15s heartbeat
    /// can't fill the log with "still throttled".
    private var lastSkipLog: Date?
    private var inFlight: Task<Void, Never>?

    private let log = Logger(subsystem: "com.shaheer.clauderunway", category: "usage")

    init(history: HistoryStore = HistoryStore(),
         notifier: Notifier = Notifier(),
         webFetcher: @escaping () async throws -> UsageSnapshot = { try await WebUsageAPI.fetch() },
         oauthFetcher: @escaping () async throws -> UsageSnapshot = { try await UsageAPI.fetch() }) {
        self.history = history
        self.notifier = notifier
        self.webFetcher = webFetcher
        self.oauthFetcher = oauthFetcher

        // Show the last known numbers immediately rather than an empty bar.
        self.snapshot = history.loadCachedSnapshot()

        // Gate state describes our *request history* and is kept separately from
        // the cached reading — otherwise a restart would either bypass the floor
        // or wrongly suppress the first fetch.
        self.lastAttempt = Self.storedDate(.lastAttempt)
        self.lastSuccess = Self.storedDate(.lastSuccess)
        for t in [Transport.web, .oauth] {
            if let until = Self.storedThrottle(t), until > Date() {
                self.throttles[t] = until
            }
        }
        self.throttledUntil = self.throttles[
            RefreshGate.transport(hasSessionKey: self.hasSessionKey, sessionExpired: false)
        ]

        history.prune()
        reloadSeries()
    }

    func start() {
        // A short heartbeat rather than one long timer: it recovers correctly
        // after sleep, where a long timer would simply fire late.
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfDue() }
        }
        requestRefresh(reason: "launch")
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        inFlight?.cancel()
    }

    // MARK: - Session key

    /// Returns false if the pasted value doesn't look like a session key.
    @discardableResult
    func setSessionKey(_ raw: String) -> Bool {
        guard SessionKeyStore.looksValid(raw), SessionKeyStore.save(raw) else { return false }

        // A new key may belong to a different account, so the cached org ID
        // must not be reused.
        SessionKeyStore.organizationID = nil
        hasSessionKey = true
        sessionExpired = false
        lastError = nil
        requestRefresh(reason: "session key added", force: true)
        return true
    }

    func clearSessionKey() {
        SessionKeyStore.delete()
        SessionKeyStore.organizationID = nil
        hasSessionKey = false
        sessionExpired = false
    }

    // MARK: - Refresh gating

    private func refreshIfDue() {
        guard let last = lastSuccess else { requestRefresh(reason: "no data yet"); return }
        if Date().timeIntervalSince(last) >= transport.pollInterval {
            requestRefresh(reason: "scheduled")
        }
    }

    /// Event-driven refresh (popover opened, woke from sleep, Claude Code wrote
    /// to disk). Coalesced by the transport's minimum interval.
    func requestRefresh(reason: String, force: Bool = false) {
        let now = Date()
        let active = transport

        // Only the active transport's own penalty applies.
        throttledUntil = throttles[active]

        guard RefreshGate.shouldFetch(now: now,
                                      lastAttempt: lastAttempt,
                                      throttledUntil: throttles[active],
                                      minInterval: active.minInterval,
                                      force: force) else {
            logSkip(active, now: now)
            return
        }
        guard inFlight == nil else { return }

        lastAttempt = now
        Self.store(.lastAttempt, now)
        isRefreshing = true
        log.info("fetching via \(active.label, privacy: .public) (\(reason, privacy: .public))")
        DebugLog.write("fetch [\(active.label)]: \(reason)")

        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let snap = try await (active == .web ? self.webFetcher() : self.oauthFetcher())
                self.handleSuccess(snap)
            } catch {
                self.handleFailure(error, transport: active)
            }
            self.inFlight = nil
            self.isRefreshing = false
        }
    }

    /// Explains why nothing is happening — otherwise a throttled app looks
    /// identical to a broken one in the log.
    private func logSkip(_ active: Transport, now: Date) {
        if let last = lastSkipLog, now.timeIntervalSince(last) < 60 { return }
        lastSkipLog = now

        if let until = throttles[active], now < until {
            DebugLog.write("skip [\(active.label)]: throttled for \(Int(until.timeIntervalSince(now)))s")
        } else if let last = lastAttempt {
            let wait = Int(active.minInterval - now.timeIntervalSince(last))
            DebugLog.write("skip [\(active.label)]: \(wait)s until next allowed request")
        }
    }

    private func handleSuccess(_ snap: UsageSnapshot) {
        DebugLog.write("ok: " + snap.buckets.map { "\($0.key)=\(Int($0.percent))%" }.joined(separator: " "))
        snapshot = snap
        lastError = nil
        lastSuccess = snap.fetchedAt
        Self.store(.lastSuccess, snap.fetchedAt)

        let active = transport
        backoffs[active] = 0
        throttles[active] = nil
        throttledUntil = nil
        Self.storeThrottle(active, nil)
        history.save(snap)
        notifier.evaluate(snap)

        // save() writes asynchronously; re-read after it lands so the sparkline
        // includes the reading that just arrived.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.reloadSeries()
        }
    }

    private func reloadSeries() {
        recentSeries = history.series(since: Date().addingTimeInterval(-24 * 3600))
    }

    private func handleFailure(_ error: Error, transport active: Transport) {
        DebugLog.write("FAIL [\(active.label)]: \(error)")
        log.error("fetch failed: \(String(describing: error), privacy: .public)")

        switch error {
        case UsageError.sessionExpired, UsageError.noSessionKey:
            // Drop to the OAuth path rather than leaving the user with nothing.
            sessionExpired = true
            lastError = UsageError.sessionExpired.errorDescription
            // The fallback transport has its own (much longer) floor, so let the
            // next heartbeat pick it up instead of firing immediately.

        case UsageError.rateLimited(let retryAfter):
            let next = RefreshGate.nextBackoff(current: backoffs[active] ?? 0)
            backoffs[active] = next
            let wait = max(retryAfter ?? 0, next)
            let until = Date().addingTimeInterval(wait)
            throttles[active] = until
            throttledUntil = until
            Self.storeThrottle(active, until)
            lastError = "Rate limited — retrying in \(Int(wait / 60)) min"

        default:
            throttles[active] = nil
            throttledUntil = nil
            Self.storeThrottle(active, nil)
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Persisted gate state

    /// Kept in UserDefaults rather than the snapshot file: these describe our
    /// *request history*, which must outlive the process even when no
    /// successful reading was ever stored.
    private enum GateKey: String {
        case lastAttempt = "gate.lastAttempt"
        case lastSuccess = "gate.lastSuccess"
    }

    private static func throttleKey(_ t: Transport) -> String { "gate.throttledUntil.\(t.label)" }

    private static func storeThrottle(_ t: Transport, _ date: Date?) {
        let key = throttleKey(t)
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func storedThrottle(_ t: Transport) -> Date? {
        let raw = UserDefaults.standard.double(forKey: throttleKey(t))
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private static func store(_ key: GateKey, _ date: Date?) {
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
    }

    private static func storedDate(_ key: GateKey) -> Date? {
        let raw = UserDefaults.standard.double(forKey: key.rawValue)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    // MARK: - Derived state for the UI

    /// Human summary of why the numbers might not be current.
    var statusLine: String {
        if isRefreshing { return "Refreshing…" }
        if let error = lastError { return error }
        guard let snap = snapshot else { return "No data yet" }

        let seconds = Int(Date().timeIntervalSince(snap.fetchedAt))
        let age = seconds < 60 ? "just now" : "\(seconds / 60) min ago"
        return "Updated \(age) · \(transport.label)" + (snap.isStale() ? " · stale" : "")
    }
}
