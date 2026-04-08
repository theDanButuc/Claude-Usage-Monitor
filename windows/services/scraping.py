"""
WebScrapingService — port of ClaudeUsageMonitor/Services/WebScrapingService.swift

Uses Playwright (Chromium) with a persistent browser context so the Claude.ai
session cookie is saved across runs (equivalent to WKWebsiteDataStore.default()).

The JS fetch/XHR interceptor is injected at document-start via
page.add_init_script().  Instead of window.webkit.messageHandlers the script
calls window.__usageCallback__(payload) which is exposed to the page via
page.expose_function().
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

from urllib.parse import urlparse

from playwright.sync_api import Browser, BrowserContext, Page, sync_playwright

from models import UsageData

logger = logging.getLogger(__name__)

try:
    from playwright_stealth import Stealth as _Stealth
    _STEALTH = _Stealth()
    logger.info("playwright-stealth loaded")
except Exception as _stealth_err:
    logger.warning("playwright-stealth unavailable: %s", _stealth_err)
    _STEALTH = None

# Claude's session (rate-limit) window is at most 5 hours; anything longer is a
# billing/subscription reset, not a session reset.
_MAX_SESSION_WINDOW_SECONDS = 6 * 3600

# ── Paths ──────────────────────────────────────────────────────────────────────

_APP_DATA = Path(os.environ.get("APPDATA", Path.home())) / "ClaudeUsageMonitor"
BROWSER_DATA_DIR = _APP_DATA / "browser_data"
LOGIN_PROFILE_DIR = _APP_DATA / "login_profile"  # separate dir — no lock conflict
USAGE_URL = "https://claude.ai/settings/usage"
LOGIN_URL = "https://claude.ai/login"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

# ── Interceptor JS (injected at document start) ───────────────────────────────
# Wraps fetch + XHR and forwards every API JSON response to Python via the
# exposed __usageCallback__ function.

_INTERCEPTOR_JS = r"""
(function() {
    const _send = (payload) => {
        try { window.__usageCallback__(JSON.stringify(payload)); }
        catch(e) {}
    };

    const _tryForward = (text, url) => {
        if (!text || text.length < 10 || text.length > 500000) return;
        if (url.indexOf('.js') !== -1 || url.indexOf('.css') !== -1 ||
            url.indexOf('i18n') !== -1 || url.indexOf('statsig') !== -1) return;
        try {
            const json = JSON.parse(text);
            if (text.indexOf('{') !== -1 && /:\s*\d/.test(text)) {
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

# ── DOM extraction JS (fallback, runs ~5 s after page load) ───────────────────

_DOM_JS = r"""
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
        var titleLower = document.title.toLowerCase();
        if (url.includes('/login') || url.includes('/auth') ||
            titleLower.includes('sign in') || titleLower.includes('log in')) {
            r.needsLogin = true; return JSON.stringify(r);
        }
        // Check page content for login wall (Claude may stay on /settings/usage
        // but render a sign-in prompt without changing the URL).
        var bodyText = (document.body && document.body.innerText) || '';
        var bodyLower = bodyText.toLowerCase();
        var hasLoginWall = (
            (bodyLower.includes('sign in') || bodyLower.includes('log in')) &&
            !bodyLower.includes('usage') &&
            !bodyLower.includes('messages')
        );
        if (hasLoginWall) {
            r.needsLogin = true; return JSON.stringify(r);
        }

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
            body = parts.join(' ').replace(/\s+/g, ' ').trim();
        } catch(e) { body = document.body ? document.body.innerText : ''; }

        var nextData = '';
        try {
            var nd = window.__NEXT_DATA__;
            if (nd) nextData = JSON.stringify(nd).substring(0, 2000);
        } catch(e) {}
        r.rawText = (body.substring(0, 2000) + ' ' + nextData).trim();

        var plans = [[/claude\s+max|\bmax\s+plan/i,'Max'],[/claude\s+pro|\bpro\s+plan/i,'Pro'],
                     [/claude\s+team|\bteam\s+plan/i,'Team'],[/\bfree\s+plan|claude\s+free/i,'Free']];
        for (var p of plans) { if (p[0].test(body)) { r.planType = p[1]; break; } }

        var specificPatterns = [
            /(\d+)\s+of\s+(\d+)\s+(?:usage\s+)?messages?/i,
            /(\d+)\s+messages?\s+(?:of|out\s+of)\s+(\d+)/i,
            /(\d+)\s*\/\s*(\d+)\s+messages?/i,
            /messages?[:\s]+(\d+)\s*(?:\/|of)\s*(\d+)/i,
        ];
        for (var sp of specificPatterns) {
            var sm = body.match(sp);
            if (sm) {
                r.messagesUsed  = parseInt(sm[1]);
                r.messagesLimit = parseInt(sm[2]);
                break;
            }
        }

        if (r.messagesLimit <= 0) {
            var bars = Array.from(document.querySelectorAll('[role="progressbar"]'));
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

        if (r.messagesLimit <= 0) {
            var allPairs = [];
            var re = /(\d+)\s*(?:of|\/|out of)\s*(\d+)/gi, m;
            while ((m = re.exec(body)) !== null) {
                var u = parseInt(m[1]), l = parseInt(m[2]);
                if (l > 0 && u <= l) allPairs.push([u, l]);
            }
            if (allPairs.length > 0) {
                allPairs.sort((a,b) => b[1]-a[1]);
                r.messagesUsed  = allPairs[0][0];
                r.messagesLimit = allPairs[0][1];
            }
        }

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

        var allResets = Array.from(body.matchAll(/resets?\s+in\s+(\d[^\n]{2,30}?)(?=\s*\d{2,3}%|\s*Last|$)/gi));
        if (allResets.length > 0) r.sessionResetStr = allResets[0][1].trim();
        if (allResets.length > 1) r.weeklyResetStr  = allResets[1][1].trim();
        if (!r.weeklyResetStr) {
            var dayPat = /(?:Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?)\s+(?:at\s+)?\d{1,2}:\d{2}\s*(?:AM|PM)/i;
            var wr = body.match(dayPat);
            if (wr) r.weeklyResetStr = wr[0].trim();
        }
        var rd = body.match(/resets?\s+(?:on\s+)?([A-Z][a-z]+\s+\d{1,2}(?:,?\s*\d{4})?)/i);
        if (rd) r.resetDateStr = rd[1].trim();

        if (/rate\s+limit(?:ed)?/i.test(body)) r.rateLimitStatus = 'Limited';

    } catch(e) { r.error = e.toString(); }
    return JSON.stringify(r);
})();
"""


def _is_login_url(url: str) -> bool:
    """Return True if the URL looks like an auth/login redirect.

    Mirrors the Mac app's check: url.contains("/login") || url.contains("/auth")
    || url.contains("?next="). This catches /login, /auth, challenge_redirect
    URLs with ?to=.../login in the query string, and ?next= redirects.
    """
    return "/login" in url or "/auth" in url or "?next=" in url or "?to=" in url


def _is_usage_url(url: str) -> bool:
    """Return True only when the URL's path is /settings/usage."""
    try:
        return urlparse(url).path.rstrip("/") == "/settings/usage"
    except Exception:
        return False


# ── Service ────────────────────────────────────────────────────────────────────

class WebScrapingService:
    """Thread-safe scraping service backed by a Playwright persistent context."""

    def __init__(self) -> None:
        self.usage_data: UsageData | None = None
        self.is_loading: bool = False
        self.needs_login: bool = False
        self.error_message: str | None = None

        # Callbacks (set by the app controller)
        self.on_usage_updated: Callable[[UsageData | None], None] | None = None
        self.on_needs_login: Callable[[], None] | None = None
        self.on_login_success: Callable[[], None] | None = None

        self._lock = threading.Lock()
        self._playwright = None
        self._context: BrowserContext | None = None
        self._page: Page | None = None
        self._started = False
        self._browser_thread_obj: threading.Thread | None = None
        self._pending_session_cookies: list = []  # cookies captured from login browser

        # Signals for the browser thread (all Playwright calls must stay on that thread)
        self._pending_refresh = threading.Event()
        self._pending_dom_extraction = False
        self._pending_cookie_injection: list | None = None
        self._should_stop = False

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def start(self) -> None:
        """Launch the Playwright browser in a background thread."""
        if self._started:
            return
        self._should_stop = False
        self._pending_refresh.clear()
        self._started = True
        t = threading.Thread(target=self._browser_thread, daemon=True)
        self._browser_thread_obj = t
        t.start()

    def _browser_thread(self) -> None:
        BROWSER_DATA_DIR.mkdir(parents=True, exist_ok=True)
        logger.debug("Browser data dir: %s", BROWSER_DATA_DIR)
        pw = sync_playwright().start()
        self._playwright = pw

        context = pw.chromium.launch_persistent_context(
            user_data_dir=str(BROWSER_DATA_DIR),
            headless=True,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--disable-infobars",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-features=IsolateOrigins,site-per-process",
            ],
            user_agent=USER_AGENT,
            no_viewport=True,
            ignore_default_args=["--enable-automation"],
        )
        logger.info("Headless browser started (playwright-chromium)")
        self._context = context

        # Inject session cookies captured from the login browser, if any.
        if self._pending_session_cookies:
            try:
                context.add_cookies(self._pending_session_cookies)
                logger.info("Injected %d session cookies from login browser", len(self._pending_session_cookies))
            except Exception as exc:
                logger.warning("Cookie injection failed: %s", exc)
            self._pending_session_cookies = []

        self._log_cookies("headless context started")

        page = context.new_page() if not context.pages else context.pages[0]
        self._page = page

        if _STEALTH is not None:
            try:
                _STEALTH.apply_stealth_sync(page)
                logger.info("Stealth evasions applied to page")
            except Exception as exc:
                logger.warning("Stealth apply failed: %s", exc)

        # Expose a Python function to JavaScript as window.__usageCallback__
        page.expose_function("__usageCallback__", self._on_js_message)
        page.add_init_script(_INTERCEPTOR_JS)
        page.on("load", self._on_page_load)

        # Initial navigation
        self._navigate_to_usage()

        # Main browser loop — ALL Playwright page calls must happen on this thread.
        # The loop services refresh requests and DOM extraction so that no other
        # thread ever touches a Playwright page object.
        try:
            while not self._should_stop:
                if self._pending_refresh.wait(timeout=0.25):
                    self._pending_refresh.clear()
                    # Inject any cookies queued from the UI before navigating.
                    if self._pending_cookie_injection is not None:
                        cookies = self._pending_cookie_injection
                        self._pending_cookie_injection = None
                        try:
                            self._context.add_cookies(cookies)
                            self._log_cookies("after-injection")
                        except Exception as exc:
                            logger.warning("Cookie injection failed: %s", exc)
                    if not self._should_stop:
                        self._navigate_to_usage()
                    continue
                if self._pending_dom_extraction:
                    self._pending_dom_extraction = False
                    self._do_dom_extraction()
        finally:
            # Clean up on this thread — Playwright's sync API is thread-local,
            # so context/playwright must be closed here, not from another thread.
            logger.debug("Browser thread exiting — closing context")
            try:
                if self._context is not None:
                    self._context.close()
            except Exception as exc:
                logger.debug("Context close error: %s", exc)
            try:
                if self._playwright is not None:
                    self._playwright.stop()
            except Exception as exc:
                logger.debug("Playwright stop error: %s", exc)
            with self._lock:
                self._context = None
                self._page = None
                self._playwright = None
            logger.debug("Browser thread cleanup done")

    def _log_cookies(self, context_label: str) -> None:
        """Log Claude-domain cookies for debugging auth state."""
        try:
            ctx = self._context
            if ctx is None:
                logger.debug("[cookies/%s] no context", context_label)
                return
            all_cookies = ctx.cookies("https://claude.ai")
            if not all_cookies:
                logger.debug("[cookies/%s] no cookies for claude.ai — not signed in", context_label)
            else:
                names = [c["name"] for c in all_cookies]
                logger.debug("[cookies/%s] %d cookie(s): %s", context_label, len(all_cookies), names)
        except Exception as exc:
            logger.debug("[cookies/%s] could not read cookies: %s", context_label, exc)

    def _navigate_to_usage(self) -> None:
        if self._page is None:
            return
        try:
            self.is_loading = True
            logger.debug("Navigating to %s", USAGE_URL)
            self._page.goto(USAGE_URL, wait_until="domcontentloaded", timeout=30_000)
            url = self._page.url
            logger.debug("Landed on: %s", url)
            self._log_cookies("post-navigate")
            if url and (_is_login_url(url) or not _is_usage_url(url)):
                logger.info("Redirected to auth/non-usage page → needs login (url=%s)", url)
                self._trigger_needs_login()
            else:
                logger.debug("On usage page — session appears valid")
        except Exception as exc:
            logger.warning("Navigation error: %s", exc)
            self.is_loading = False
            self.error_message = str(exc)
            if self.on_usage_updated:
                self.on_usage_updated(None)

    # ── Public API ─────────────────────────────────────────────────────────────

    def initial_load(self) -> None:
        """Called once at startup; start() must be called before this."""
        # Navigation is triggered inside _browser_thread already.
        pass

    def refresh(self) -> None:
        """Force a reload of the usage page."""
        with self._lock:
            if self.is_loading:
                return
        if self._page is None:
            return
        # Clear stale session fields
        if self.usage_data is not None:
            self.usage_data.session_used = 0
            self.usage_data.session_limit = 0
            self.usage_data.reset_date = None
            self.usage_data.weekly_reset_date = None
            self.usage_data.weekly_reset_text = ""
        self.is_loading = True
        # Signal the browser thread to navigate — never call page.goto() from here
        self._pending_refresh.set()

    def inject_session_cookie(self, cookie_str: str) -> None:
        """Inject a session cookie pasted by the user and trigger a refresh.

        Accepts either ``name=value`` (e.g. ``sessionKey=abc123``) or a bare
        value (assumed to be ``sessionKey``).  The injection is queued for the
        browser thread so Playwright's thread-local API is respected.
        """
        cookie_str = cookie_str.strip()
        if not cookie_str:
            return

        # Parse "name=value" or treat the whole string as the value.
        if "=" in cookie_str and len(cookie_str.split("=", 1)[0]) < 64:
            name, value = cookie_str.split("=", 1)
        else:
            name, value = "sessionKey", cookie_str

        name = name.strip()
        value = value.strip()
        logger.info("Injecting session cookie: name=%s value=%s…", name, value[:8])

        self._pending_cookie_injection = [{
            "name": name,
            "value": value,
            "domain": ".claude.ai",
            "path": "/",
            "secure": True,
            "httpOnly": True,
            "sameSite": "Lax",
        }]
        self.needs_login = False
        self._pending_refresh.set()

    # ── JS message handler ─────────────────────────────────────────────────────

    def _on_js_message(self, raw: str) -> None:
        try:
            outer = json.loads(raw)
            url = outer.get("url", "")
            data = outer.get("data")
            if isinstance(data, dict):
                logger.debug("API intercept from %s — keys: %s", url, list(data.keys())[:10])
                self._apply_api_result(data)
        except Exception as exc:
            logger.debug("JS message parse error: %s", exc)

    # ── Page load handler ──────────────────────────────────────────────────────

    def _on_page_load(self) -> None:
        if self._page is None:
            return
        url = self._page.url
        if not url or url == "about:blank":
            return

        logger.debug("Page load event: %s", url)

        if _is_login_url(url):
            logger.info("Page load is a login/auth URL → needs login (url=%s)", url)
            self._trigger_needs_login()
            return

        if _is_usage_url(url):
            # Signal the browser-thread loop to run DOM extraction.
            # No Playwright calls allowed here — this callback may fire from the
            # Playwright event loop and re-entering its sync wrapper would deadlock.
            logger.debug("Usage page loaded — queuing DOM extraction")
            self._pending_dom_extraction = True
            return

        # Any other URL (home page, etc.) also means not on the usage page.
        logger.info("Page load not on usage page (url=%s) — needs login", url)
        self._trigger_needs_login()

    def _trigger_needs_login(self) -> None:
        """Signal that login is required. Idempotent — fires the callback once."""
        with self._lock:
            if self.needs_login:
                return
            self.is_loading = False
            self.needs_login = True
        logger.info("needs_login=True — firing on_needs_login callback")
        if self.on_needs_login:
            self.on_needs_login()

    def _do_dom_extraction(self) -> None:
        """Run selector wait + JS evaluation on the browser thread."""
        if self._page is None:
            return
        logger.debug("DOM extraction starting")
        try:
            try:
                self._page.wait_for_selector('[role="progressbar"]', timeout=10_000)
                logger.debug("Progress bar selector found")
            except Exception:
                logger.debug("Progress bar selector not found within 10s — running DOM JS anyway")
            if self._page is None:
                return
            result = self._page.evaluate(_DOM_JS)
            j = json.loads(result)
            logger.debug(
                "DOM result: needsLogin=%s planType=%s messagesUsed=%s/%s sessionUsed=%s/%s",
                j.get("needsLogin"), j.get("planType"),
                j.get("messagesUsed"), j.get("messagesLimit"),
                j.get("sessionUsed"), j.get("sessionLimit"),
            )
            self.is_loading = False
            self._apply_dom_result(j)
        except Exception as exc:
            logger.warning("DOM extraction error: %s", exc)
            self.is_loading = False

    # ── Parsing ────────────────────────────────────────────────────────────────

    def _apply_api_result(self, j: dict) -> None:
        candidates = [
            (j.get("messages_used"), j.get("messages_limit"), j.get("reset_at")),
            (j.get("usage_count"),   j.get("usage_limit"),    j.get("resets_at")),
            (j.get("count"),         j.get("limit"),          j.get("reset_time")),
        ]

        nested: dict = {}
        for v in j.values():
            if isinstance(v, dict):
                nested.update(v)
            elif isinstance(v, list) and v and isinstance(v[0], dict):
                nested.update(v[0])

        candidates += [
            (nested.get("messages_used"),  nested.get("messages_limit"),  nested.get("reset_at")),
            (nested.get("messages_used"),  nested.get("messages_limit"),  nested.get("resets_at")),
            (nested.get("used"),           nested.get("limit"),           nested.get("reset_at")),
            (nested.get("used"),           nested.get("limit"),           nested.get("resets_at")),
            (nested.get("count"),          nested.get("limit"),           nested.get("reset_time")),
        ]

        for used_v, limit_v, reset_v in candidates:
            used = _int_val(used_v)
            limit = _int_val(limit_v)
            if used is None or limit is None or limit <= 0 or used > limit:
                continue
            reset_date = _parse_iso_date(reset_v)
            logger.info("API data matched: used=%s limit=%s reset=%s", used, limit, reset_v)

            with self._lock:
                data = self.usage_data or UsageData(
                    plan_type="Unknown",
                    messages_used=used,
                    messages_limit=limit,
                    reset_date=reset_date,
                    rate_limit_status="Normal",
                    last_updated=datetime.now(timezone.utc),
                )
                data.session_used = used
                data.session_limit = limit
                now = datetime.now(timezone.utc)
                if reset_date and reset_date > now:
                    if (reset_date - now).total_seconds() <= _MAX_SESSION_WINDOW_SECONDS:
                        data.reset_date = reset_date
                data.last_updated = now
                self.usage_data = data
                self.is_loading = False
                self.needs_login = False

            if self.on_usage_updated:
                self.on_usage_updated(self.usage_data)
            return

        logger.debug("API intercept: no matching usage fields found in response")

    def _apply_dom_result(self, j: dict) -> None:
        if j.get("needsLogin"):
            self._trigger_needs_login()
            return

        plan_type = j.get("planType", "Unknown")
        messages_used = j.get("messagesUsed", 0)
        messages_limit = j.get("messagesLimit", 0)
        session_used = j.get("sessionUsed", 0)
        session_limit = j.get("sessionLimit", 0)

        # If the page loaded but contained no usage data at all and we have no
        # prior data, the user is most likely not logged in (Claude renders a
        # login wall on /settings/usage without redirecting).
        if (messages_limit <= 0 and session_limit <= 0
                and plan_type == "Unknown"
                and self.usage_data is None):
            logger.warning("DOM extraction found no usage data — triggering login")
            self._trigger_needs_login()
            return
        rate_limit_status = j.get("rateLimitStatus", "Normal")
        reset_date_str = j.get("resetDateStr", "")
        session_reset_str = j.get("sessionResetStr", "")
        weekly_reset_str = j.get("weeklyResetStr", "")

        reset_date: datetime | None = None
        weekly_reset_date: datetime | None = None

        if reset_date_str:
            weekly_reset_date = _parse_month_day(reset_date_str)

        if session_reset_str:
            reset_date = _parse_relative_duration(session_reset_str)

        if weekly_reset_str and weekly_reset_date is None:
            weekly_reset_date = _parse_relative_duration(weekly_reset_str)

        with self._lock:
            data = self.usage_data or UsageData(
                plan_type=plan_type,
                messages_used=messages_used,
                messages_limit=messages_limit,
                reset_date=reset_date,
                rate_limit_status=rate_limit_status,
                last_updated=datetime.now(timezone.utc),
            )
            if not data.plan_type or data.plan_type == "Unknown":
                data.plan_type = plan_type
            if messages_limit > 0:
                data.messages_used = messages_used
                data.messages_limit = messages_limit
            if session_limit > 0:
                data.session_used = session_used
                data.session_limit = session_limit
            if reset_date and data.reset_date is None:
                data.reset_date = reset_date
            if weekly_reset_date:
                data.weekly_reset_date = weekly_reset_date
                data.weekly_reset_text = ""
            # Keep absolute weekday+time text (e.g. "Fri 10:00 AM")
            if weekly_reset_str and re.search(r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)", weekly_reset_str):
                data.weekly_reset_text = weekly_reset_str
            data.rate_limit_status = rate_limit_status
            data.last_updated = datetime.now(timezone.utc)
            self.usage_data = data
            self.error_message = None
            self.needs_login = False

        logger.info(
            "DOM data applied: plan=%s messages=%s/%s session=%s/%s",
            data.plan_type, data.messages_used, data.messages_limit,
            data.session_used, data.session_limit,
        )
        if self.on_usage_updated:
            self.on_usage_updated(self.usage_data)


# ── Helpers ────────────────────────────────────────────────────────────────────

def _int_val(v) -> int | None:
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v)
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            return None
    return None


def _parse_iso_date(v) -> datetime | None:
    if not isinstance(v, str) or not v:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            dt = datetime.strptime(v, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


def _parse_relative_duration(s: str) -> datetime | None:
    """Parse '2 hours', '30 minutes', '1 day', '2h 30m' → absolute datetime."""
    total_seconds = 0.0
    lower = s.lower()
    pattern = r"(\d+)\s*(day|hour|hr|min|h|d|m)s?"
    for m in re.finditer(pattern, lower):
        value = float(m.group(1))
        unit = m.group(2)
        if unit in ("d", "day"):
            total_seconds += value * 86400
        elif unit in ("h", "hr", "hour"):
            total_seconds += value * 3600
        elif unit in ("m", "min"):
            total_seconds += value * 60
    if total_seconds <= 0:
        return None
    return datetime.now(timezone.utc) + timedelta(seconds=total_seconds)


def _parse_month_day(s: str) -> datetime | None:
    """Parse 'December 25' or 'Dec 25, 2024' → next occurrence as datetime."""
    now = datetime.now(timezone.utc)
    for fmt in ("%B %d, %Y", "%B %d", "%b %d, %Y", "%b %d"):
        try:
            parsed = datetime.strptime(s, fmt)
            candidate = parsed.replace(year=now.year, tzinfo=timezone.utc)
            if candidate < now:
                candidate = candidate.replace(year=now.year + 1)
            return candidate
        except ValueError:
            continue
    return None
