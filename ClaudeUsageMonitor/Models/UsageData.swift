import Foundation

struct UsageData {
    var planType:        String
    var messagesUsed:    Int        // billing-period total (from DOM)
    var messagesLimit:   Int        // billing-period limit  (from DOM)
    var sessionUsed:     Int = 0   // current rate-limit window (from API interceptor)
    var sessionLimit:    Int = 0   // current rate-limit window (from API interceptor)
    var resetDate:       Date?
    var rateLimitStatus: String
    var lastUpdated:     Date

    // MARK: - Computed

    var hasSessionData: Bool { sessionLimit > 0 }

    /// What to show in the ring and menu bar:
    /// session window when available (what the user asked for), billing period as fallback.
    var primaryUsed:  Int { hasSessionData ? sessionUsed  : messagesUsed  }
    var primaryLimit: Int { hasSessionData ? sessionLimit : messagesLimit }

    var usagePercentage: Double {
        guard primaryLimit > 0 else { return 0 }
        return min(1.0, Double(primaryUsed) / Double(primaryLimit))
    }

    var messagesRemaining: Int { max(0, primaryLimit - primaryUsed) }

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

    /// Label shown in the menu bar: "51/100"
    var menuBarLabel: String {
        guard primaryLimit > 0 else { return "" }
        return "\(primaryUsed)/\(primaryLimit)"
    }

    /// True when the last successful update is older than 10 minutes.
    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 600
    }
}
