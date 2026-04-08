import WebKit
import Combine
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Fallback DOM extraction (runs if direct API calls fail).
// Waits for React to render, then pulls values from visible text and aria bars.
// ─────────────────────────────────────────────────────────────────────────────
private let kDOMExtractionJS = """
(function() {
    var r = {
        planType: 'Unknown', messagesUsed: -1, messagesLimit: -1,
        sessionUsed: -1, sessionLimit: -1,
        resetDateStr: '', sessionResetStr: '', weeklyResetStr: '',
        rateLimitStatus: 'Normal', needsLogin: false, source: 'dom',
        rawText: ''
    };
    try {
        var url = window.location.href;
        if (url.includes('/login') || url.includes('/auth') ||
            document.title.toLowerCase().includes('sign in')) {
            r.needsLogin = true; return JSON.stringify(r);
        }

        // Gather only visible text nodes — skip script/style/noscript entirely
        var body = '';
        try {
            var walker = document.createTreeWalker(
                document.body,
                NodeFilter.SHOW_TEXT,
                { acceptNode: function(node) {
                    var p = node.parentElement;
                    while (p) {
                        var t = p.tagName;
                        if (t === 'SCRIPT' || t === 'STYLE' || t === 'NOSCRIPT') return NodeFilter.FILTER_REJECT;
                        p = p.parentElement;
                    }
                    return node.textContent.trim().length > 0 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
                }}
            );
            var parts = [];
            while (walker.nextNode()) { parts.push(walker.currentNode.textContent.trim()); }
            body = parts.join(' ').replace(/\\s+/g, ' ').trim();
        } catch(e) { body = document.body ? document.body.innerText : ''; }
        // Also check Next.js / React global state for reset info
        var nextData = '';
        try {
            var nd = window.__NEXT_DATA__;
            if (nd) nextData = JSON.stringify(nd).substring(0, 2000);
        } catch(e) {}
        r.rawText = (body.substring(0, 2000) + ' ' + nextData).trim();

        // Plan
        var plans = [[/claude\\s+max|\\bmax\\s+plan/i,'Max'],[/claude\\s+pro|\\bpro\\s+plan/i,'Pro'],
                     [/claude\\s+team|\\bteam\\s+plan/i,'Team'],[/\\bfree\\s+plan|claude\\s+free/i,'Free']];
        for (var p of plans) { if (p[0].test(body)) { r.planType = p[1]; break; } }

        // ── aria progressbars (first = session, last = period) ───────────────
        var bars = Array.from(document.querySelectorAll('[role="progressbar"]'));
        if (bars.length >= 2) {
            r.sessionUsed  = parseInt(bars[0].getAttribute('aria-valuenow')||'0');
            r.sessionLimit = parseInt(bars[0].getAttribute('aria-valuemax')||'0');
            r.messagesUsed = parseInt(bars[bars.length-1].getAttribute('aria-valuenow')||'0');
            r.messagesLimit= parseInt(bars[bars.length-1].getAttribute('aria-valuemax')||'0');
        } else if (bars.length === 1) {
            r.messagesUsed = parseInt(bars[0].getAttribute('aria-valuenow')||'0');
            r.messagesLimit= parseInt(bars[0].getAttribute('aria-valuemax')||'0');
        }

        // Reset dates
        var allResets = Array.from(body.matchAll(/resets?\\s+in\\s+(\\d[^\\n]{2,30}?)(?=\\s*\\d{2,3}%|\\s*Last|$)/gi));
        if (allResets.length > 0) r.sessionResetStr = allResets[0][1].trim();
        if (allResets.length > 1) r.weeklyResetStr  = allResets[1][1].trim();
        if (!r.weeklyResetStr) {
            var dayPat = /(?:Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?)\\s+(?:at\\s+)?\\d{1,2}:\\d{2}\\s*(?:AM|PM)/i;
            var wr = body.match(dayPat);
            if (wr) r.weeklyResetStr = wr[0].trim();
        }
        var rd = body.match(/resets?\\s+(?:on\\s+)?([A-Z][a-z]+\\s+\\d{1,2}(?:,?\\s*\\d{4})?)/i);
        if (rd) r.resetDateStr = rd[1].trim();

        if (/rate\\s+limit(?:ed)?/i.test(body)) r.rateLimitStatus = 'Limited';

    } catch(e) { r.error = e.toString(); }
    return JSON.stringify(r);
})();
"""

// ─────────────────────────────────────────────────────────────────────────────
class WebScrapingService: NSObject, ObservableObject {
    static let shared = WebScrapingService()

    @Published var usageData: UsageData?
    @Published var isLoading  = false
    @Published var needsLogin = false
    @Published var errorMessage: String?

    var onLoginSuccess: (() -> Void)?

    private var scrapeWebView: WKWebView!
    private(set) var loginWebView: WKWebView?

    private let usageURL = URL(string: "https://claude.ai/settings/usage")!

    /// Cached org UUID — reset when session changes.
    private var cachedOrgID: String?

    private override init() {
        super.init()
        setupScrapeWebView()
    }

    // MARK: - Setup

    private func setupScrapeWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        scrapeWebView = WKWebView(frame: .zero, configuration: config)
        scrapeWebView.navigationDelegate = self
        scrapeWebView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    }

    // MARK: - Public API

    func initialLoad() {
        isLoading = true
        scrapeWebView.load(URLRequest(url: usageURL))
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        // Clear stale session fields while we fetch fresh data
        usageData?.sessionUsed  = 0
        usageData?.sessionLimit = 0
        usageData?.resetDate = nil
        usageData?.weeklyResetDate = nil
        usageData?.weeklyResetText = ""
        // Try direct API first; fall back to WebView load if no session cookie
        tryAPIRefresh()
    }

    func makeLoginWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = scrapeWebView.customUserAgent
        loginWebView = wv
        wv.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        return wv
    }

    // MARK: - Direct API (primary path)

    /// Try to refresh via direct API calls without loading a page.
    /// Falls back to WebView load if no session cookie is available.
    private func tryAPIRefresh() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            if let key = self.sessionKey(from: cookies) {
                self.fetchOrganizationAndUsage(sessionKey: key)
            } else {
                DispatchQueue.main.async {
                    self.scrapeWebView.load(URLRequest(url: self.usageURL))
                }
            }
        }
    }

    private func sessionKey(from cookies: [HTTPCookie]) -> String? {
        cookies.first { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }?.value
    }

    private func fetchOrganizationAndUsage(sessionKey: String) {
        if let orgID = cachedOrgID {
            fetchUsageFromEndpoint(sessionKey: sessionKey, orgID: orgID)
        } else {
            fetchOrgID(sessionKey: sessionKey) { [weak self] orgID in
                guard let self else { return }
                if let orgID {
                    self.cachedOrgID = orgID
                    self.fetchUsageFromEndpoint(sessionKey: sessionKey, orgID: orgID)
                } else {
                    // Could not get org ID — load page as fallback
                    DispatchQueue.main.async {
                        self.scrapeWebView.load(URLRequest(url: self.usageURL))
                    }
                }
            }
        }
    }

    private func fetchOrgID(sessionKey: String, completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
        applyAPIHeaders(to: &req, sessionKey: sessionKey)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data,
                  let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = orgs.first
            else { completion(nil); return }
            let uuid = first["uuid"] as? String ?? first["id"] as? String
            completion(uuid)
        }.resume()
    }

    private func fetchUsageFromEndpoint(sessionKey: String, orgID: String) {
        let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!
        var req = URLRequest(url: url)
        applyAPIHeaders(to: &req, sessionKey: sessionKey)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
                // Session expired
                self.cachedOrgID = nil
                DispatchQueue.main.async { self.isLoading = false; self.needsLogin = true }
                return
            }
            guard let data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // API failed — fall back to DOM scraping
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scrapeWebView.load(URLRequest(url: self.usageURL))
                }
                return
            }
            self.applyDirectAPIResult(body)
        }.resume()
    }

    private func applyAPIHeaders(to request: inout URLRequest, sessionKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
    }

    /// Parse the /api/organizations/{id}/usage response.
    /// Keys: five_hour.utilization (0–100), five_hour.resets_at,
    ///       seven_day.utilization (0–100), seven_day.resets_at,
    ///       rate_limit_tier
    private func applyDirectAPIResult(_ body: [String: Any]) {
        var fiveHourPct:   Double? = nil
        var fiveHourReset: Date?   = nil
        var sevenDayPct:   Double? = nil
        var sevenDayReset: Date?   = nil
        var planType = "Unknown"

        if let fh = body["five_hour"] as? [String: Any] {
            fiveHourPct   = doubleValue(fh["utilization"])
            fiveHourReset = parseResetDate(fh["resets_at"])
        }
        if let sd = body["seven_day"] as? [String: Any] {
            sevenDayPct   = doubleValue(sd["utilization"])
            sevenDayReset = parseResetDate(sd["resets_at"])
        }
        if let tier = body["rate_limit_tier"] as? String {
            planType = normalizePlanTier(tier)
        }

        guard fiveHourPct != nil || sevenDayPct != nil else {
            // Unexpected shape — fall back to DOM
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runDOMExtraction()
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            var data = self.usageData ?? UsageData(
                planType: planType,
                messagesUsed: 0, messagesLimit: 0,
                resetDate: fiveHourReset,
                rateLimitStatus: "Normal",
                lastUpdated: Date()
            )

            if data.planType == "Unknown" || data.planType.isEmpty { data.planType = planType }

            // five_hour → session window
            if let pct = fiveHourPct {
                data.sessionUsed  = Int(pct.rounded())
                data.sessionLimit = 100
                if let rd = fiveHourReset { data.resetDate = rd }
            }

            // seven_day → weekly usage
            if let pct = sevenDayPct {
                data.messagesUsed  = Int(pct.rounded())
                data.messagesLimit = 100
                if let rd = sevenDayReset { data.weeklyResetDate = rd }
            }

            data.lastUpdated = Date()
            self.usageData   = data
            self.isLoading   = false
            self.needsLogin  = false
            self.errorMessage = nil
        }
    }

    // MARK: - DOM extraction (fallback)

    private func runDOMExtraction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.scrapeWebView.evaluateJavaScript(kDOMExtractionJS) { result, _ in
                guard let self,
                      let s = result as? String,
                      let d = s.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return }
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.applyDOMResult(j)
                }
            }
        }
    }

    // MARK: - Parsing

    private func applyDOMResult(_ j: [String: Any]) {
        if j["needsLogin"] as? Bool == true { needsLogin = true; return }

        let planType        = j["planType"]        as? String ?? "Unknown"
        let messagesUsed    = j["messagesUsed"]    as? Int    ?? 0
        let messagesLimit   = j["messagesLimit"]   as? Int    ?? 0
        let sessionUsed     = j["sessionUsed"]     as? Int    ?? 0
        let sessionLimit    = j["sessionLimit"]    as? Int    ?? 0
        let rateLimitStatus  = j["rateLimitStatus"]  as? String ?? "Normal"
        let resetDateStr     = j["resetDateStr"]     as? String ?? ""
        let sessionResetStr  = j["sessionResetStr"]  as? String ?? ""
        let weeklyResetStr   = j["weeklyResetStr"]   as? String ?? ""

        var resetDate: Date?
        var weeklyResetDate: Date?

        if !resetDateStr.isEmpty {
            let fmts = ["MMMM d, yyyy", "MMMM d", "MMM d, yyyy", "MMM d"]
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
            for fmt in fmts {
                df.dateFormat = fmt
                if let d = df.date(from: resetDateStr) {
                    let comps = Calendar.current.dateComponents([.month, .day], from: d)
                    weeklyResetDate = Calendar.current.nextDate(
                        after: Date(), matching: comps,
                        matchingPolicy: .nextTimePreservingSmallerComponents) ?? d
                    break
                }
            }
        }

        if !sessionResetStr.isEmpty {
            resetDate = parseRelativeDuration(sessionResetStr)
        }

        if !weeklyResetStr.isEmpty && weeklyResetDate == nil {
            weeklyResetDate = parseRelativeDuration(weeklyResetStr)
        }

        _ = j["rawText"]

        var data = usageData ?? UsageData(
            planType: planType, messagesUsed: messagesUsed, messagesLimit: messagesLimit,
            resetDate: resetDate, rateLimitStatus: rateLimitStatus, lastUpdated: Date()
        )
        if data.planType == "Unknown" || data.planType.isEmpty { data.planType = planType }
        if messagesLimit > 0 {
            data.messagesUsed  = messagesUsed
            data.messagesLimit = messagesLimit
        }
        if sessionLimit > 0 {
            data.sessionUsed  = sessionUsed
            data.sessionLimit = sessionLimit
        }
        if let rd = resetDate, data.resetDate == nil { data.resetDate = rd }
        if let wd = weeklyResetDate { data.weeklyResetDate = wd; data.weeklyResetText = "" }
        let looksAbsolute = weeklyResetStr.range(of: #"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)"#, options: .regularExpression) != nil
        if !weeklyResetStr.isEmpty && looksAbsolute { data.weeklyResetText = weeklyResetStr }
        data.rateLimitStatus = rateLimitStatus
        data.lastUpdated = Date()

        usageData    = data
        errorMessage = nil
        needsLogin   = false
    }

    // MARK: - Helpers

    private func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int    { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int    { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// Map API rate_limit_tier values to display names.
    private func normalizePlanTier(_ tier: String) -> String {
        let lower = tier.lowercased()
        if lower.contains("max")  { return "Max" }
        if lower.contains("pro")  { return "Pro" }
        if lower.contains("team") { return "Team" }
        if lower.contains("free") { return "Free" }
        return tier
    }

    private func parseRelativeDuration(_ s: String) -> Date? {
        var totalSeconds: Double = 0
        let lower = s.lowercased()
        let pattern = #"(\d+)\s*(day|hour|hr|min|h|d|m)s?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let matches = regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        guard !matches.isEmpty else { return nil }
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: lower),
                  let unitRange  = Range(match.range(at: 2), in: lower),
                  let value = Double(lower[valueRange])
            else { continue }
            switch String(lower[unitRange]) {
            case "d", "day":         totalSeconds += value * 86400
            case "h", "hr", "hour": totalSeconds += value * 3600
            case "m", "min":        totalSeconds += value * 60
            default: break
            }
        }
        guard totalSeconds > 0 else { return nil }
        return Date().addingTimeInterval(totalSeconds)
    }

    private func parseResetDate(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

// MARK: - WKNavigationDelegate

extension WebScrapingService: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let s = url.absoluteString

        if webView === scrapeWebView {
            if s.contains("/login") || s.contains("/auth") || s.contains("?next=") {
                DispatchQueue.main.async { self.isLoading = false; self.needsLogin = true }
            } else if s.contains("settings/usage") {
                // Page loaded — extract session cookie and call API directly
                fetchUsageViaAPIAfterPageLoad()
            } else if s.contains("claude.ai") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.scrapeWebView.load(URLRequest(url: self.usageURL))
                }
            }
        } else if webView === loginWebView {
            if !s.contains("/login") && !s.contains("/auth") {
                DispatchQueue.main.async { self.onLoginSuccess?() }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === scrapeWebView {
            DispatchQueue.main.async { self.isLoading = false; self.errorMessage = error.localizedDescription }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        if webView === scrapeWebView {
            DispatchQueue.main.async { self.isLoading = false; self.errorMessage = error.localizedDescription }
        }
    }

    /// Called after settings/usage page loads — pulls session cookie from WebView store
    /// and fires direct API calls. Falls back to DOM extraction if cookie unavailable.
    private func fetchUsageViaAPIAfterPageLoad() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            if let key = self.sessionKey(from: cookies) {
                self.fetchOrganizationAndUsage(sessionKey: key)
            } else {
                DispatchQueue.main.async { self.runDOMExtraction() }
            }
        }
    }
}
