import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    /// Thresholds (as integer percentages) already notified in the current session.
    /// Cleared when usage drops back below a threshold.
    private var notifiedThresholds = Set<Int>()

    /// Date of the last known reset, used to detect when a new window starts.
    private var lastKnownResetDate: Date?

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Usage threshold alerts

    func checkAndNotify(data: UsageData) {
        checkUsageThresholds(data: data)
        checkSessionReset(data: data)
    }

    private func checkUsageThresholds(data: UsageData) {
        let pct = data.usagePercentage
        let thresholds = [80, 90, 100]

        for threshold in thresholds {
            let thresholdFraction = Double(threshold) / 100.0
            if pct >= thresholdFraction {
                guard !notifiedThresholds.contains(threshold) else { continue }
                notifiedThresholds.insert(threshold)
                sendUsageAlert(used: data.primaryUsed, limit: data.primaryLimit, percentage: threshold)
            } else {
                // Reset so the notification fires again if usage climbs back up
                notifiedThresholds.remove(threshold)
            }
        }
    }

    private func sendUsageAlert(used: Int, limit: Int, percentage: Int) {
        let content = UNMutableNotificationContent()
        content.title = percentage >= 100 ? "Claude Limit Reached" : "Claude Usage Warning"
        content.body  = "\(used)/\(limit) messages used (\(percentage)%)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claude-usage-\(percentage)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Session reset detection

    private func checkSessionReset(data: UsageData) {
        guard let newReset = data.resetDate else { return }

        if let known = lastKnownResetDate, newReset > known.addingTimeInterval(3600) {
            // Reset date jumped forward by > 1 hour → a new window started
            notifiedThresholds.removeAll()
            sendResetNotification()
        }

        lastKnownResetDate = newReset
    }

    private func sendResetNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Claude Session Reset"
        content.body  = "Your usage window has reset. You have a full quota available."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claude-reset-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
