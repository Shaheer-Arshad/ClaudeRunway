import Foundation
import UserNotifications

/// Fires a single notification per limit per reset window once usage crosses 90%.
///
/// Dedupe key is bucket + reset timestamp, persisted in UserDefaults so a
/// relaunch (or the 15-minute poll seeing the same high number again) doesn't
/// re-notify. When the window rolls over, `resets_at` changes and the key with it.
final class Notifier {
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
        var notified = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
        let liveKeys = Set(snapshot.buckets.map(windowKey))

        for bucket in snapshot.buckets where bucket.percent >= Urgency.notifyThreshold {
            let key = windowKey(bucket)
            guard !notified.contains(key) else { continue }
            notified.insert(key)
            deliver("Claude usage at \(Int(bucket.percent))%",
                    "\(bucket.displayName) is nearly exhausted.")
        }

        // Drop keys for windows that no longer exist so the list can't grow
        // without bound across weeks of resets.
        defaults.set(Array(notified.intersection(liveKeys)), forKey: defaultsKey)
    }

    private func windowKey(_ bucket: LimitBucket) -> String {
        let reset = bucket.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "\(bucket.key)@\(reset)"
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
