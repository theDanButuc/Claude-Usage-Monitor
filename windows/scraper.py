"""Fetches Claude.ai usage data via curl_cffi API calls."""

import json
import os
import sys
import tempfile
from datetime import datetime, timezone

from curl_cffi import requests

RATE_LIMITS_PATH = os.path.join(os.path.expanduser("~"), ".claude", "rate-limits.json")

APP_DATA_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "ClaudeUsageMonitor")
SESSION_PATH = os.path.join(APP_DATA_DIR, "session.json")

if getattr(sys, "frozen", False):
    PROJECT_DIR = os.path.dirname(sys.executable)
else:
    PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

API_BASE = "https://claude.ai/api"


def scrape_usage() -> dict | None:
    """Fetch usage data from Claude.ai API using curl_cffi."""
    session = _load_session()
    if not session:
        print("[scraper] No session saved. Run: python -m scraper --login")
        return None

    session_key = session.get("session_key", "")
    org_id = session.get("org_id", "")

    if not session_key:
        print("[scraper] No session_key in session.json")
        return None

    # Get org ID if we don't have one cached
    if not org_id:
        org_id = _get_org_id(session_key)
        if org_id:
            session["org_id"] = org_id
            _save_session(session)
        else:
            print("[scraper] Could not get org ID")
            return None

    # Fetch usage
    data = _fetch_usage(session_key, org_id)
    if data:
        _write_rate_limits(data)
        print(f"[scraper] OK: 5h={data['five_hour']['used_percentage']}%, 7d={data['seven_day']['used_percentage']}%, Sonnet={data['sonnet']['used_percentage']}%")
    else:
        print("[scraper] Failed to fetch usage data")

    return data


def _load_session() -> dict | None:
    if not os.path.exists(SESSION_PATH):
        return None
    try:
        with open(SESSION_PATH, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def _save_session(session: dict):
    os.makedirs(APP_DATA_DIR, exist_ok=True)
    with open(SESSION_PATH, "w") as f:
        json.dump(session, f, indent=2)


def _make_headers(session_key: str) -> dict:
    return {
        "Accept": "application/json",
        "Accept-Language": "en-US,en;q=0.9",
        "Cookie": f"sessionKey={session_key}",
        "Referer": "https://claude.ai/settings/usage",
        "Origin": "https://claude.ai",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }


def _get_org_id(session_key: str) -> str | None:
    try:
        resp = requests.get(
            f"{API_BASE}/organizations",
            headers=_make_headers(session_key),
            impersonate="chrome124",
            timeout=10,
        )
        if resp.status_code == 200:
            orgs = resp.json()
            if isinstance(orgs, list) and orgs:
                return orgs[0].get("uuid") or orgs[0].get("id")
    except Exception as e:
        print(f"[scraper] Org fetch error: {e}")
    return None


def _fetch_usage(session_key: str, org_id: str) -> dict | None:
    url = f"{API_BASE}/organizations/{org_id}/usage"
    try:
        resp = requests.get(
            url,
            headers=_make_headers(session_key),
            impersonate="chrome124",
            timeout=10,
        )
        if resp.status_code == 200:
            body = resp.json()
            print(f"[scraper] API keys: {list(body.keys())}")
            return _parse_response(body)
        elif resp.status_code == 403:
            print("[scraper] 403 — session key may be expired. Re-run: python -m scraper --login")
        else:
            print(f"[scraper] API returned {resp.status_code}")
    except Exception as e:
        print(f"[scraper] Fetch error: {e}")
    return None


def _parse_response(body: dict) -> dict | None:
    result = {
        "last_updated": datetime.now(timezone.utc).isoformat(),
        "model": "Unknown",
        "five_hour": {"used_percentage": None, "resets_at": None},
        "seven_day": {"used_percentage": None, "resets_at": None},
        "sonnet": {"used_percentage": None, "resets_at": None},
    }

    # Parse five_hour
    fh = body.get("five_hour")
    if isinstance(fh, dict):
        result["five_hour"]["used_percentage"] = fh.get("utilization")
        resets = fh.get("resets_at")
        if isinstance(resets, str):
            try:
                result["five_hour"]["resets_at"] = datetime.fromisoformat(resets).timestamp()
            except ValueError:
                pass

    # Parse seven_day
    sd = body.get("seven_day")
    if isinstance(sd, dict):
        result["seven_day"]["used_percentage"] = sd.get("utilization")
        resets = sd.get("resets_at")
        if isinstance(resets, str):
            try:
                result["seven_day"]["resets_at"] = datetime.fromisoformat(resets).timestamp()
            except ValueError:
                pass

    # Parse sonnet (various possible key names)
    for key in ("seven_day_sonnet", "sonnet", "sonnet_only", "seven_day_sonnet_only"):
        sn = body.get(key)
        if isinstance(sn, dict):
            result["sonnet"]["used_percentage"] = sn.get("utilization")
            resets = sn.get("resets_at")
            if isinstance(resets, str):
                try:
                    result["sonnet"]["resets_at"] = datetime.fromisoformat(resets).timestamp()
                except ValueError:
                    pass
            break

    # Plan tier from rate_limits endpoint
    if "rate_limit_tier" in body:
        result["model"] = body["rate_limit_tier"]

    found = (
        result["five_hour"]["used_percentage"] is not None
        or result["seven_day"]["used_percentage"] is not None
    )
    return result if found else None


def _write_rate_limits(data: dict):
    tmp_path = None
    try:
        os.makedirs(os.path.dirname(RATE_LIMITS_PATH), exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            dir=os.path.dirname(RATE_LIMITS_PATH), suffix=".tmp"
        )
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, RATE_LIMITS_PATH)
    except OSError:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def _login_interactive():
    """Interactive login: extract session key from browser cookies."""
    print("Opening browser to log in to Claude.ai...")
    print("After logging in, the session key will be extracted automatically.\n")

    try:
        from playwright.sync_api import sync_playwright
        browser_data = os.path.join(PROJECT_DIR, "browser_data")
        os.makedirs(browser_data, exist_ok=True)

        with sync_playwright() as p:
            browser = p.chromium.launch_persistent_context(
                user_data_dir=browser_data,
                headless=False,
                args=["--disable-blink-features=AutomationControlled"],
            )
            page = browser.pages[0] if browser.pages else browser.new_page()
            page.goto("https://claude.ai/settings/usage", wait_until="networkidle", timeout=60000)

            if "/login" in page.url or "/oauth" in page.url:
                print("Please log in to Claude.ai in the browser window...")
                page.wait_for_url("**/settings/**", timeout=300000)
                page.wait_for_load_state("networkidle", timeout=15000)

            # Extract session key from cookies
            cookies = browser.cookies()
            session_key = None
            for c in cookies:
                if c["name"] == "sessionKey" and "claude.ai" in c.get("domain", ""):
                    session_key = c["value"]
                    break

            browser.close()

            if session_key:
                # Get org ID
                org_id = _get_org_id(session_key) or ""
                _save_session({"session_key": session_key, "org_id": org_id})
                print(f"\nSession saved to {SESSION_PATH}")
                print(f"Org ID: {org_id}")

                # Test it
                data = _fetch_usage(session_key, org_id)
                if data:
                    print(f"5-hour: {data['five_hour']['used_percentage']}%")
                    print(f"Weekly: {data['seven_day']['used_percentage']}%")
                else:
                    print("Warning: could not fetch usage data with this session")
            else:
                print("Error: could not find sessionKey cookie")

    except ImportError:
        print("Playwright not installed. Install with: pip install playwright && playwright install chromium")
        print("\nOr manually set your session key:")
        print(f'  echo {{"session_key": "YOUR_KEY"}} > {SESSION_PATH}')


if __name__ == "__main__":
    import sys
    if "--login" in sys.argv:
        _login_interactive()
    else:
        data = scrape_usage()
        if data:
            print(json.dumps(data, indent=2))