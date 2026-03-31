import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    /// Thresholds already notified in the current session window.
    private var notifiedThresholds = Set<Int>()

    /// Last known reset date — used to detect when a new window starts.
    private var lastKnownResetDate: Date?

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Main entry point

    func checkAndNotify(data: UsageData) {
        checkUsageThresholds(data: data)
        checkSessionReset(data: data)
    }

    // MARK: - Usage threshold alerts

    private func checkUsageThresholds(data: UsageData) {
        // Use sessionPercentage (rate-limit window), fall back to usagePercentage
        let pct = data.hasSessionData ? data.sessionPercentage : data.usagePercentage

        let config: [(threshold: Int, title: String, body: String)] = [
            (75, "Halfway through your session",
                 "Consider wrapping up long threads. Start fresh conversations for new topics."),
            (80, "Session at 80%",
                 "Avoid new long projects or file uploads. Best for: quick questions, short edits, code review."),
            (90, "Session at 90% — act fast",
                 "~10% left. Finish your current task and save important outputs before the limit hits."),
            (95, "Almost out",
                 "Save your work now. \(data.sessionResetLabel ?? "Session resets soon")."),
            (100, "Claude Limit Reached",
                  "You've used your full quota. \(data.sessionResetLabel ?? "Resets soon").")
        ]

        for item in config {
            let fraction = Double(item.threshold) / 100.0
            if pct >= fraction {
                guard !notifiedThresholds.contains(item.threshold) else { continue }
                notifiedThresholds.insert(item.threshold)
                sendAlert(title: item.title, body: item.body, id: "claude-tip-\(item.threshold)")
            } else {
                notifiedThresholds.remove(item.threshold)
            }
        }
    }

    private func sendAlert(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Session reset detection

    private func checkSessionReset(data: UsageData) {
        guard let newReset = data.resetDate else { return }

        if let known = lastKnownResetDate, newReset > known.addingTimeInterval(3600) {
            notifiedThresholds.removeAll()
            sendAlert(
                title: "Claude Session Reset",
                body: "Your usage window has reset. You have a full quota available.",
                id: "claude-reset-\(Int(Date().timeIntervalSince1970))"
            )
        }

        lastKnownResetDate = newReset
    }
}
