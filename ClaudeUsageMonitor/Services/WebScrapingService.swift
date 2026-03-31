import WebKit
import Combine
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Injected at document START – wraps fetch/XHR before any page JS runs.
// Every response whose URL or body looks usage-related is forwarded to Swift
// via the "usageHandler" message handler.
// ─────────────────────────────────────────────────────────────────────────────
private let kInterceptorJS = """
(function() {
    const _send = (payload) => {
        try { window.webkit.messageHandlers.usageHandler.postMessage(JSON.stringify(payload)); }
        catch(e) {}
    };

    const _tryForward = (text, url) => {
        if (!text || text.length < 10 || text.length > 500000) return;
        // Skip static assets and i18n files
        if (url.indexOf('.js') !== -1 || url.indexOf('.css') !== -1 ||
            url.indexOf('i18n') !== -1 || url.indexOf('statsig') !== -1) return;
        try {
            const json = JSON.parse(text);
            // Capture any API JSON that has at least one numeric value
            if (text.indexOf('{') !== -1 && /:\\s*\\d/.test(text)) {
                _send({ type: 'api', url: url, data: json });
            }
        } catch(e) {}
    };

    // ── fetch wrapper ──────────────────────────────────────────────────────
    const _origFetch = window.fetch;
    window.fetch = function(...args) {
        const url = (args[0] instanceof Request ? args[0].url : String(args[0] || ''));
        return _origFetch.apply(this, args).then(resp => {
            resp.clone().text().then(t => _tryForward(t, url)).catch(()=>{});
            return resp;
        });
    };

    // ── XHR wrapper ────────────────────────────────────────────────────────
    const _origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(m, url, ...rest) {
        this.__url = url;
        return _origOpen.apply(this, [m, url, ...rest]);
    };
    const _origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function(...args) {
        this.addEventListener('load', () => _tryForward(this.responseText, this.__url || ''));
        return _origSend.apply(this, args);
    };
})();
"""

// ─────────────────────────────────────────────────────────────────────────────
// Fallback DOM extraction (runs after 2.5 s to let React render).
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

        // Gather all visible text from every element (React may not populate body.innerText)
        var body = document.body ? document.body.innerText : '';
        if (!body || body.trim().length < 20) {
            body = Array.from(document.querySelectorAll('*'))
                .map(function(el) { return el.textContent || ''; })
                .join(' ')
                .replace(/\\s+/g, ' ').trim();
        }
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

        // ── Specific patterns first (most reliable) ──────────────────────
        var specificPatterns = [
            /(\\d+)\\s+of\\s+(\\d+)\\s+(?:usage\\s+)?messages?/i,
            /(\\d+)\\s+messages?\\s+(?:of|out\\s+of)\\s+(\\d+)/i,
            /(\\d+)\\s*\\/\\s*(\\d+)\\s+messages?/i,
            /messages?[:\\s]+(\\d+)\\s*(?:\\/|of)\\s*(\\d+)/i,
        ];
        for (var sp of specificPatterns) {
            var sm = body.match(sp);
            if (sm) {
                r.messagesUsed  = parseInt(sm[1]);
                r.messagesLimit = parseInt(sm[2]);
                break;
            }
        }

        // ── aria progressbar (single authoritative value) ─────────────────
        if (r.messagesLimit <= 0) {
            var bars = Array.from(document.querySelectorAll('[role="progressbar"]'));
            // Use the LAST bar — Claude puts the primary usage bar last
            for (var i = bars.length - 1; i >= 0; i--) {
                var now = bars[i].getAttribute('aria-valuenow');
                var max = bars[i].getAttribute('aria-valuemax');
                if (now !== null && max !== null && parseInt(max) > 0) {
                    r.messagesUsed  = parseInt(now);
                    r.messagesLimit = parseInt(max);
                    break;
                }
            }
        }

        // ── Generic "X / Y" fallback — take the pair with the largest limit
        if (r.messagesLimit <= 0) {
            var allPairs = [];
            var re = /(\\d+)\\s*(?:of|\\/|out of)\\s*(\\d+)/gi, m;
            while ((m = re.exec(body)) !== null) {
                var u = parseInt(m[1]), l = parseInt(m[2]);
                if (l > 0 && u <= l) allPairs.push([u, l]);
            }
            if (allPairs.length > 0) {
                allPairs.sort((a,b) => b[1]-a[1]);   // largest limit first
                r.messagesUsed  = allPairs[0][0];
                r.messagesLimit = allPairs[0][1];
            }
        }

        // aria progressbars (multiple: first = session, last = period)
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
        // Weekly reset: "Resets Fri 10:00 AM" or "Resets on December 25"
        var wr = body.match(/resets?\\s+((?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\\s+\\d{1,2}:\\d{2}\\s*(?:AM|PM))/i);
        if (wr) r.weeklyResetStr = wr[1].trim();
        var rd = body.match(/resets?\\s+(?:on\\s+)?([A-Z][a-z]+\\s+\\d{1,2}(?:,?\\s*\\d{4})?)/i);
        if (rd) r.resetDateStr = rd[1].trim();
        // Session reset: "Resets in 4 hr 29 min"
        var sd = body.match(/resets?\\s+in\\s+(\\d[^\\n.]{2,30})/i);
        if (sd) r.sessionResetStr = sd[1].trim();

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

    private override init() {
        super.init()
        setupScrapeWebView()
    }

    // MARK: - Setup

    private func setupScrapeWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // Interceptor runs before any page JS
        let interceptor = WKUserScript(source: kInterceptorJS,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false)
        config.userContentController.addUserScript(interceptor)
        config.userContentController.add(self, name: "usageHandler")

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
        usageData?.sessionUsed  = 0
        usageData?.sessionLimit = 0
        scrapeWebView.load(URLRequest(url: usageURL))
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

    /// Called from the fetch/XHR interceptor via message handler.
    private func applyAPIResult(_ json: [String: Any]) {

        // ── 1. Extract reset date from anywhere in the JSON (independently of usage counts)
        if let rd = findResetDate(in: json) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.usageData?.resetDate == nil {
                    self.usageData?.resetDate = rd
                }
            }
        }

        // ── 2. Try to find session/window usage counts
        let candidates: [(used: Any?, limit: Any?, reset: Any?)] = [
            (json["messages_used"],   json["messages_limit"],   json["reset_at"]),
            (json["usage_count"],     json["usage_limit"],      json["resets_at"]),
            (json["count"],           json["limit"],            json["reset_time"]),
        ]

        // Also look one level deep
        var nested: [String: Any] = [:]
        for (_, v) in json {
            if let sub = v as? [String: Any] {
                nested.merge(sub) { a, _ in a }
                if let arr = v as? [[String: Any]], let first = arr.first {
                    nested.merge(first) { a, _ in a }
                }
            }
        }
        let nestedCandidates: [(used: Any?, limit: Any?, reset: Any?)] = [
            (nested["messages_used"],  nested["messages_limit"],  nested["reset_at"]),
            (nested["messages_used"],  nested["messages_limit"],  nested["resets_at"]),
            (nested["used"],           nested["limit"],           nested["reset_at"]),
            (nested["used"],           nested["limit"],           nested["resets_at"]),
            (nested["count"],          nested["limit"],           nested["reset_time"]),
        ]

for c in (candidates + nestedCandidates) {
            let used  = intValue(c.used)
            let limit = intValue(c.limit)
            guard let u = used, let l = limit, l > 0, u <= l else { continue }

            let resetDate = parseResetDate(c.reset)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // API interceptor fires before DOM extraction (which waits 2.5 s).
                // API responses contain the current rate-limit window → session fields.
                var data = self.usageData ?? UsageData(
                    planType: "Unknown", messagesUsed: u, messagesLimit: l,
                    resetDate: resetDate, rateLimitStatus: "Normal", lastUpdated: Date()
                )
                data.sessionUsed  = u
                data.sessionLimit = l
                if let rd = resetDate { data.resetDate = rd }
                data.lastUpdated  = Date()
                self.usageData  = data
                self.isLoading  = false
                self.needsLogin = false
            }
            return
        }
    }

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

        // 1. Absolute date string: "resets on December 25" → billing-period / weekly reset
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

        // 2. Relative duration string: "2 hours", "30 minutes" → session reset
        if !sessionResetStr.isEmpty {
            resetDate = parseRelativeDuration(sessionResetStr)
        }

        let rawText = j["rawText"] as? String ?? ""

        var data = usageData ?? UsageData(
            planType: planType, messagesUsed: messagesUsed, messagesLimit: messagesLimit,
            resetDate: resetDate, rateLimitStatus: rateLimitStatus, lastUpdated: Date()
        )
        if data.planType == "Unknown" || data.planType.isEmpty { data.planType = planType }
        if messagesLimit > 0 {
            data.messagesUsed  = messagesUsed
            data.messagesLimit = messagesLimit
        }
        // First progressbar = current session window; second = billing period.
        // Only write if DOM found two bars (sessionLimit > 0).
        if sessionLimit > 0 {
            data.sessionUsed  = sessionUsed
            data.sessionLimit = sessionLimit
        }
        if let rd = resetDate, data.resetDate == nil { data.resetDate = rd }
        if let wd = weeklyResetDate { data.weeklyResetDate = wd }
        if !weeklyResetStr.isEmpty { data.weeklyResetText = weeklyResetStr }
        data.rateLimitStatus = rateLimitStatus
        data.lastUpdated = Date()

        usageData    = data
        errorMessage = nil
        needsLogin   = false
    }

    // MARK: - Helpers

    private func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// Recursively searches a JSON dict for any reset date field and returns the nearest future one.
    private func findResetDate(in json: [String: Any]) -> Date? {
        let resetKeys = ["reset_at", "resets_at", "reset_time"]
        var found: [Date] = []

        func search(_ dict: [String: Any], depth: Int) {
            guard depth < 4 else { return }
            for (key, val) in dict {
                if resetKeys.contains(key), let d = parseResetDate(val) { found.append(d) }
                if let sub = val as? [String: Any] { search(sub, depth: depth + 1) }
                if let arr = val as? [[String: Any]] { arr.forEach { search($0, depth: depth + 1) } }
            }
        }
        search(json, depth: 0)

        let now = Date()
        return found.filter { $0 > now }.min()
    }

    /// Parses strings like "2 hours", "30 minutes", "1 day", "2h 30m", "45 mins"
    /// into an absolute Date offset from now.
    private func parseRelativeDuration(_ s: String) -> Date? {
        var totalSeconds: Double = 0
        let lower = s.lowercased()

        // Match patterns like "2 hours", "30 minutes", "1 day", "45 mins", "2h", "30m"
        let pattern = #"(\d+)\s*(day|hour|hr|min|h|d|m)s?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let matches = regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        guard !matches.isEmpty else { return nil }

        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: lower),
                  let unitRange  = Range(match.range(at: 2), in: lower),
                  let value = Double(lower[valueRange])
            else { continue }
            let unit = String(lower[unitRange])
            switch unit {
            case "d", "day":          totalSeconds += value * 86400
            case "h", "hr", "hour":  totalSeconds += value * 3600
            case "m", "min":         totalSeconds += value * 60
            default: break
            }
        }

        guard totalSeconds > 0 else { return nil }
        return Date().addingTimeInterval(totalSeconds)
    }

    private func parseResetDate(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        // ISO 8601
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
                runDOMExtraction()
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
}

// MARK: - WKScriptMessageHandler

extension WebScrapingService: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let d = body.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return }

        // Unwrap the interceptor envelope: { type, url, data }
        if let data = j["data"] as? [String: Any] {
            applyAPIResult(data)
        }
    }
}

