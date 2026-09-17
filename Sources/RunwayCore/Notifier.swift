import Foundation
import UserNotifications

/// Fires at most one notification per threshold (85%, 90%, 97%) per limit per
/// reset window.
///
/// State is persisted in UserDefaults as bucket key -> (reset time, thresholds
/// already fired), so a relaunch or repeated polls don't re-notify. `resets_at`
/// can drift by seconds-to-minutes between polls, so a window only counts as
/// new when its reset moves by more than `windowTolerance`.
final class Notifier {
    static let thresholds: [Int] = [85, 90, 97]
    private static let windowTolerance: TimeInterval = 30 * 60

    private let defaultsKey = "notifiedWindows"
    private let defaults: UserDefaults
    private let deliver: (String, String) -> Void

    init(defaults: UserDefaults = .standard,
         deliver: ((String, String) -> Void)? = nil) {
        self.defaults = defaults
        self.deliver = deliver ?? Notifier.postSystemNotification
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ snapshot: UsageSnapshot) {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
        var next: [String: [String: Any]] = [:]

        for bucket in snapshot.buckets {
            let reset = bucket.resetsAt?.timeIntervalSince1970 ?? 0
            var fired: Set<Int> = []
            if let prev = stored[bucket.key],
               let prevReset = prev["reset"] as? Double,
               abs(prevReset - reset) <= Notifier.windowTolerance {
                fired = Set(prev["fired"] as? [Int] ?? [])
            }

            // Only announce the highest newly crossed threshold, so a jump from
            // 80% to 98% between polls produces one notification, not three.
            let crossed = Notifier.thresholds.filter { bucket.percent >= Double($0) }
            if let top = crossed.last, !fired.contains(top) {
                deliver("Claude usage at \(Int(bucket.percent))%",
                        top >= 97 ? "\(bucket.displayName) is nearly exhausted."
                                  : "\(bucket.displayName) passed \(top)%.")
            }
            fired.formUnion(crossed)

            // Buckets missing from the snapshot are dropped, so state can't grow
            // without bound.
            next[bucket.key] = ["reset": reset, "fired": fired.sorted()]
        }

        defaults.set(next, forKey: defaultsKey)
    }

    private static func postSystemNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
