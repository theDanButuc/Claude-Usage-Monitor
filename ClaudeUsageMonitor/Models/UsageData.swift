import Foundation

struct UsageData {
    var planType:        String
    var messagesUsed:    Int        // billing-period total (from DOM)
    var messagesLimit:   Int        // billing-period limit  (from DOM)
    var sessionUsed:     Int = 0   // current rate-limit window (from API interceptor)
    var sessionLimit:    Int = 0   // current rate-limit window (from API interceptor)
    var resetDate:       Date?     // near-term reset (session window, from API)
    var weeklyResetDate: Date?     // billing period / weekly reset (from DOM parsed date)
    var weeklyResetText: String = "" // raw weekday+time string e.g. "Fri 10:00 AM"
    var rateLimitStatus: String
    var lastUpdated:     Date

    // MARK: - Computed

    var hasSessionData: Bool { sessionLimit > 0 }

    /// What to show in the menu bar primary percentage:
    /// session window when available, billing period as fallback.
    var primaryUsed:  Int { hasSessionData ? sessionUsed  : messagesUsed  }
    var primaryLimit: Int { hasSessionData ? sessionLimit : messagesLimit }

    var usagePercentage: Double {
        guard primaryLimit > 0 else { return 0 }
        return min(1.0, Double(primaryUsed) / Double(primaryLimit))
    }

    var sessionPercentage: Double {
        guard sessionLimit > 0 else { return 0 }
        return min(1.0, Double(sessionUsed) / Double(sessionLimit))
    }

    var weeklyPercentage: Double {
        guard messagesLimit > 0 else { return 0 }
        return min(1.0, Double(messagesUsed) / Double(messagesLimit))
    }

    var messagesRemaining: Int { max(0, primaryLimit - primaryUsed) }

    var timeUntilReset: String {
        guard let resetDate else { return "—" }
        let secs = resetDate.timeIntervalSince(Date())
        guard secs > 0 else { return "Soon" }
        let totalMins = Int(secs / 60)
        let h = totalMins / 60
        let m = totalMins % 60
        let days = h / 24
        if days > 0  { return "\(days)d \(h % 24)h" }
        if h > 0     { return "\(h)h \(m)m" }
        if m > 0     { return "\(m)m" }
        return "< 1m"
    }

    /// "Resets in 4 hr 29 min" for the session bar, nil if unknown or already past
    var sessionResetLabel: String? {
        guard let date = resetDate else { return nil }
        let secs = date.timeIntervalSince(Date())
        guard secs > 60 else { return nil }   // past or < 1 min — hide rather than show "Soon"
        let totalMins = Int(secs / 60)
        let h = totalMins / 60
        let m = totalMins % 60
        if h > 0 { return "Resets in \(h) hr \(m) min" }
        return "Resets in \(m) min"
    }

    /// "Resets Fri 10:00 AM" for the weekly bar
    var weeklyResetLabel: String? {
        if !weeklyResetText.isEmpty { return "Resets \(weeklyResetText)" }
        guard let date = weeklyResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "Resets \(f.string(from: date))"
    }

    var lastUpdatedFormatted: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: lastUpdated)
    }

    /// "x% | y%" for the macOS menu bar (Current session | Weekly limits)
    var menuBarLabel: String {
        let sPct = hasSessionData ? "\(Int(sessionPercentage * 100))%" : nil
        let wPct = messagesLimit > 0 ? "\(Int(weeklyPercentage * 100))%" : nil
        switch (sPct, wPct) {
        case let (s?, w?): return "\(s) | \(w)"
        case let (s?, nil): return s
        case let (nil, w?): return w
        default: return ""
        }
    }

    /// True when the last successful update is older than 10 minutes.
    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 600
    }
}
