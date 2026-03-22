import Foundation

struct UsageData {
    var planType:        String
    var messagesUsed:    Int
    var messagesLimit:   Int
    var sessionUsed:     Int = 0
    var sessionLimit:    Int = 0
    var resetDate:       Date?
    var rateLimitStatus: String
    var lastUpdated:     Date

    // MARK: - Computed

    var hasSessionData: Bool { sessionLimit > 0 }

    // Always drive the UI from the primary (billing-period) numbers.
    // Session data is shown in a secondary card only when present.
    var usagePercentage: Double {
        guard messagesLimit > 0 else { return 0 }
        return min(1.0, Double(messagesUsed) / Double(messagesLimit))
    }

    var messagesRemaining: Int { max(0, messagesLimit - messagesUsed) }

    var timeUntilReset: String {
        guard let resetDate else { return "Unknown" }
        let secs = resetDate.timeIntervalSince(Date())
        guard secs > 0 else { return "Soon" }
        let h = Int(secs / 3600)
        let m = Int(secs.truncatingRemainder(dividingBy: 3600) / 60)
        if h > 24 { return "\(h/24)d \(h%24)h" }
        if h > 0  { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var lastUpdatedFormatted: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: lastUpdated)
    }

    /// Short string shown in the menu bar: "45/100"
    var menuBarLabel: String {
        guard messagesLimit > 0 else { return "" }
        return "\(messagesUsed)/\(messagesLimit)"
    }
}
