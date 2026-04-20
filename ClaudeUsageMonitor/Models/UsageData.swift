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
    var extraUsageSpent: Double = 0  // € spent on extra usage this billing period
    var extraUsageLimit: Double = 0  // € monthly spend limit for extra usage
    var sonnetPercentage: Double = 0 // seven_day_sonnet utilization (0–1), Max users only
    var sonnetResetDate: Date? = nil // seven_day_sonnet.resets_at
    var claudeDesignPercentage: Double = 0 // seven_day_claude_design utilization (0–1)
    var claudeDesignResetDate: Date? = nil // seven_day_claude_design.resets_at
    var routineRunsUsed:  Int = 0   // daily routine runs used (/v1/code/routines/run-budget)
    var routineRunsLimit: Int = 0   // daily routine runs limit (plan-specific: Pro=5, Max=15, Team/Enterprise=25)
    var rateLimitStatus: String
    var lastUpdated:     Date

    // MARK: - Burn rate history
    // Rolling window of (timestamp, sessionPercentage) — max 10 points
    var usageHistory: [(date: Date, pct: Double)] = []

    // MARK: - Computed

    var hasSessionData: Bool { sessionLimit > 0 }

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

    var hasExtraUsage: Bool { extraUsageLimit > 0 }

    var hasSonnetData: Bool { sonnetPercentage > 0 }

    var hasClaudeDesignData: Bool { claudeDesignPercentage > 0 }

    var hasRoutineData: Bool { routineRunsLimit > 0 }

    var routineRunsPercentage: Double {
        guard routineRunsLimit > 0 else { return 0 }
        return min(1.0, Double(routineRunsUsed) / Double(routineRunsLimit))
    }

    var routineRunsRemaining: Int { max(0, routineRunsLimit - routineRunsUsed) }

    var sonnetResetLabel: String? {
        guard let date = sonnetResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "Resets \(f.string(from: date))"
    }

    var claudeDesignResetLabel: String? {
        guard let date = claudeDesignResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "Resets \(f.string(from: date))"
    }

    var extraUsagePercentage: Double {
        guard extraUsageLimit > 0 else { return 0 }
        return min(1.0, extraUsageSpent / extraUsageLimit)
    }

    var messagesRemaining: Int { max(0, primaryLimit - primaryUsed) }

    // MARK: - Burn rate

    /// Messages-per-minute consumed based on rolling history.
    /// Returns nil if < 2 points or < 5 minutes of data (too noisy).
    var burnRatePerMinute: Double? {
        guard usageHistory.count >= 2 else { return nil }
        let oldest = usageHistory.first!
        let newest = usageHistory.last!
        let minutes = newest.date.timeIntervalSince(oldest.date) / 60.0
        guard minutes >= 5 else { return nil }
        let consumed = newest.pct - oldest.pct
        guard consumed > 0 else { return nil }
        return consumed / minutes
    }

    /// Estimated minutes until session hits 100%, capped at actual resetDate.
    var estimatedMinutesRemaining: Double? {
        guard let rate = burnRatePerMinute, rate > 0 else { return nil }
        let remaining = 1.0 - sessionPercentage
        let estimated = remaining / rate
        if let reset = resetDate {
            let actual = reset.timeIntervalSince(Date()) / 60.0
            guard actual > 0 else { return nil }
            return min(estimated, actual)
        }
        return estimated
    }

    /// "~45min left" or "~2h 3m left" — nil if burn rate unavailable
    var burnRateLabel: String? {
        guard let mins = estimatedMinutesRemaining else { return nil }
        if mins < 60 { return "~\(Int(mins))min left" }
        let h = Int(mins / 60)
        let m = Int(mins.truncatingRemainder(dividingBy: 60))
        return m > 0 ? "~\(h)h \(m)m left" : "~\(h)h left"
    }

    // MARK: - Reset labels

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

    var sessionResetLabel: String? {
        guard let date = resetDate else { return nil }
        let secs = date.timeIntervalSince(Date())
        guard secs > 60 else { return nil }
        let totalMins = Int(secs / 60)
        let h = totalMins / 60
        let m = totalMins % 60
        if h > 0 { return "Resets in \(h) hr \(m) min" }
        return "Resets in \(m) min"
    }

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

    // MARK: - Menu bar label
    var menuBarLabel: String {
        let sessionStr: String?
        if hasSessionData {
            sessionStr = "\(Int(sessionPercentage * 100))%"
        } else {
            sessionStr = nil
        }
        let wPct = messagesLimit > 0 ? "\(Int(weeklyPercentage * 100))%" : nil
        switch (sessionStr, wPct) {
        case let (s?, w?): return "\(s) | \(w)"
        case let (s?, nil): return s
        case let (nil, w?): return w
        default: return ""
        }
    }

    // MARK: - Tips

    struct UsageTip {
        let icon: String
        let message: String
        let actions: [TipAction]
    }

    struct TipAction {
        let label: String
        let copyText: String
    }

    var currentTips: [UsageTip] {
        let pct = sessionPercentage * 100
        var tips: [UsageTip] = []

        if pct >= 20 {
            tips.append(UsageTip(
                icon: "arrow.triangle.2.circlepath",
                message: "Start a new conversation for each new topic to keep context small and responses fast.",
                actions: []
            ))
        }

        if pct >= 40 {
            tips.append(UsageTip(
                icon: "bolt.fill",
                message: "Compress your session to free up context. Copy the prompt and send it in your current conversation:",
                actions: [
                    TipAction(
                        label: "claude.ai",
                        copyText: "Please summarize our conversation so far in under 200 words so we can continue efficiently."
                    ),
                    TipAction(
                        label: "/compact",
                        copyText: "/compact"
                    )
                ]
            ))
        }

        if pct >= 60 {
            tips.append(UsageTip(
                icon: "doc.fill",
                message: "Avoid re-uploading large files. Reference content already shared earlier in the conversation.",
                actions: []
            ))
        }

        if pct >= 75 {
            tips.append(UsageTip(
                icon: "checkmark.circle.fill",
                message: "Wrap up long threads. Save important outputs before your session resets.",
                actions: []
            ))
        }

        if pct >= 85 {
            tips.append(UsageTip(
                icon: "exclamationmark.triangle.fill",
                message: "Best for short tasks now: quick questions, code review, short edits. Avoid starting new long projects.",
                actions: []
            ))
        }

        if pct >= 95 {
            tips.append(UsageTip(
                icon: "xmark.octagon.fill",
                message: "Almost out. Save your work now. \(sessionResetLabel ?? "Session resets soon").",
                actions: []
            ))
        }

        return tips
    }

    // MARK: - Stale

    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 600
    }
}
