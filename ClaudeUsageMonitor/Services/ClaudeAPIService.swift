import Foundation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// ClaudeAPIService — replaces WebScrapingService.
// Fetches usage data directly from the Claude.ai API using URLSession.
// Auth: sessionKey cookie (extracted by LoginWindowController after OAuth login).
// ─────────────────────────────────────────────────────────────────────────────

final class ClaudeAPIService: ObservableObject {
    static let shared = ClaudeAPIService()

    @Published var usageData: UsageData?
    @Published var isLoading  = false
    @Published var needsLogin = false
    @Published var errorMessage: String?

    var onLoginSuccess: (() -> Void)?

    private let baseURL = "https://claude.ai/api"
    private let urlSession: URLSession

    // MARK: - Persisted credentials

    var sessionKey: String? {
        get { UserDefaults.standard.string(forKey: "claudeSessionKey") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeSessionKey") }
    }

    private var orgId: String? {
        get { UserDefaults.standard.string(forKey: "claudeOrgId") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeOrgId") }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never    // we manage cookies manually via header
        config.httpShouldSetCookies   = false
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    func initialLoad() {
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        guard let key = sessionKey, !key.isEmpty else {
            DispatchQueue.main.async { self.needsLogin = true }
            return
        }
        isLoading = true

        if let existingOrgId = orgId {
            fetchUsage(sessionKey: key, orgId: existingOrgId)
        } else {
            fetchOrgId(sessionKey: key) { [weak self] resolvedOrgId in
                guard let self else { return }
                if let id = resolvedOrgId {
                    self.orgId = id
                    self.fetchUsage(sessionKey: key, orgId: id)
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.errorMessage = "Could not fetch organization ID"
                    }
                }
            }
        }
    }

    // MARK: - Request builder

    private func makeRequest(path: String, sessionKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("empty",       forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("cors",        forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        return req
    }

    // MARK: - Network calls

    private func fetchOrgId(sessionKey: String, completion: @escaping (String?) -> Void) {
        let req = makeRequest(path: "/organizations", sessionKey: sessionKey)
        urlSession.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            if http?.statusCode == 401 || http?.statusCode == 403 {
                DispatchQueue.main.async {
                    self.sessionKey = nil
                    self.orgId = nil
                    self.isLoading = false
                    self.needsLogin = true
                }
                completion(nil)
                return
            }
            guard let data,
                  http?.statusCode == 200,
                  let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = orgs.first,
                  let uuid = (first["uuid"] as? String) ?? (first["id"] as? String)
            else {
                completion(nil)
                return
            }
            completion(uuid)
        }.resume()
    }

    private func fetchUsage(sessionKey: String, orgId: String) {
        let req = makeRequest(path: "/organizations/\(orgId)/usage", sessionKey: sessionKey)
        urlSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                let http = response as? HTTPURLResponse
                if http?.statusCode == 401 || http?.statusCode == 403 {
                    self.sessionKey = nil
                    self.orgId = nil
                    self.needsLogin = true
                    return
                }
                guard let data, error == nil else {
                    self.errorMessage = error?.localizedDescription ?? "Network error"
                    return
                }
                guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.errorMessage = "Invalid API response"
                    return
                }
                self.usageData    = APIResponseParser.parse(body)
                self.errorMessage = nil
                self.needsLogin   = false
            }
        }.resume()
    }

}

// MARK: - Response parser

private enum APIResponseParser {

    static func parse(_ body: [String: Any]) -> UsageData {
        let fiveHour    = body["five_hour"]        as? [String: Any]
        let sevenDay    = body["seven_day"]        as? [String: Any]
        let extraUsage  = body["extra_usage"]      as? [String: Any]

        // Sonnet key may vary — try most common names
        let sonnet: [String: Any]? = (body["seven_day_sonnet"]      as? [String: Any])
                                  ?? (body["sonnet"]                as? [String: Any])
                                  ?? (body["sonnet_only"]           as? [String: Any])
                                  ?? (body["seven_day_sonnet_only"] as? [String: Any])

        let tierRaw = body["rate_limit_tier"] as? String ?? ""

        let sessionPct  = utilization(fiveHour)
        let weeklyPct   = utilization(sevenDay)
        let sonnetPct   = utilization(sonnet)

        let resetDate       = isoDate(fiveHour?["resets_at"])
        let weeklyResetDate = isoDate(sevenDay?["resets_at"])
        let sonnetResetDate = isoDate(sonnet?["resets_at"])

        // Synthesise used/limit from percentage for backward-compat with UI (shows "42/100")
        let sessionUsed  = Int((sessionPct * 100).rounded())
        let sessionLimit = sessionPct > 0 ? 100 : 0
        let msgUsed      = Int((weeklyPct * 100).rounded())
        let msgLimit     = weeklyPct > 0 ? 100 : 0

        // Weekly reset label derived from Date (replaces raw "Fri 10:00 AM" from DOM)
        var weeklyResetText = ""
        if let wd = weeklyResetDate {
            let f = DateFormatter()
            f.dateFormat = "EEE h:mm a"
            weeklyResetText = f.string(from: wd)
        }

        var data = UsageData(
            planType:        planType(from: tierRaw),
            messagesUsed:    msgUsed,
            messagesLimit:   msgLimit,
            resetDate:       resetDate,
            rateLimitStatus: "Normal",
            lastUpdated:     Date()
        )
        data.sessionUsed      = sessionUsed
        data.sessionLimit     = sessionLimit
        data.weeklyResetDate  = weeklyResetDate
        data.weeklyResetText  = weeklyResetText
        data.sonnetPercentage = sonnetPct
        data.sonnetResetDate  = sonnetResetDate

        // Extra usage — only when is_enabled == true
        if extraUsage?["is_enabled"] as? Bool == true ||
           extraUsage?["is_enabled"] as? Int == 1 {
            data.extraUsageSpent = doubleValue(extraUsage?["used_credits"])
            data.extraUsageLimit = doubleValue(extraUsage?["monthly_limit"])
        }

        return data
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static func doubleValue(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int    { return Double(i) }
        return 0
    }

    private static func utilization(_ window: [String: Any]?) -> Double {
        guard let v = window?["utilization"] else { return 0 }
        if let d = v as? Double { return min(1.0, d / 100.0) }
        if let i = v as? Int    { return min(1.0, Double(i) / 100.0) }
        return 0
    }

    private static func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    private static func planType(from tier: String) -> String {
        let t = tier.lowercased()
        if t.contains("max")  { return "Max" }
        if t.contains("pro")  { return "Pro" }
        if t.contains("team") { return "Team" }
        if t.contains("free") { return "Free" }
        return tier.isEmpty ? "Unknown" : tier
    }
}
