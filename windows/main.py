"""
ClaudeUsageMonitor — Windows port
Entry point / application controller.

Port of AppDelegate.swift: wires together the scraping service, notification
service, update service, system-tray icon and popup window.

Usage:
    python main.py
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading
import tkinter as tk
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ── Ensure the windows/ package directory is on sys.path ─────────────────────
_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from models import UsageData
from services.scraping import WebScrapingService
from services.notifications import NotificationService
from services.updates import UpdateService
from ui.tray import TrayIcon
from ui.popup import PopupWindow

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
# Suppress noisy third-party debug logs
for _noisy in ("PIL", "asyncio", "urllib3", "playwright"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)
logger = logging.getLogger(__name__)

# ── Settings storage ──────────────────────────────────────────────────────────

_APP_DATA = Path(os.environ.get("APPDATA", Path.home())) / "ClaudeUsageMonitor"
_SETTINGS_FILE = _APP_DATA / "settings.json"

_DEFAULT_REFRESH_INTERVAL = 120.0  # seconds

# A drop of more than this percentage point indicates the session window reset.
_SESSION_RESET_THRESHOLD = 0.01


def _load_settings() -> dict[str, Any]:
    try:
        return json.loads(_SETTINGS_FILE.read_text())
    except Exception:
        return {}


def _save_settings(data: dict[str, Any]) -> None:
    _APP_DATA.mkdir(parents=True, exist_ok=True)
    _SETTINGS_FILE.write_text(json.dumps(data))


# ── App controller ─────────────────────────────────────────────────────────────

class AppController:
    def __init__(self) -> None:
        self._settings = _load_settings()
        self._refresh_interval: float = self._settings.get(
            "refreshInterval", _DEFAULT_REFRESH_INTERVAL
        )

        self._usage_history: list[tuple[datetime, float]] = []
        self._available_update: str | None = None

        # Services
        self._scraper = WebScrapingService()
        self._notifications = NotificationService()
        self._updater = UpdateService()

        # tkinter root (hidden — only the popup Toplevel is shown)
        self._root = tk.Tk()
        self._root.withdraw()
        self._root.title("Claude Usage Monitor")

        # UI
        self._popup = PopupWindow(
            root=self._root,
            on_refresh=self._refresh_now,
            on_quit=self._quit,
            on_login=self._do_login,
        )

        self._tray = TrayIcon(
            on_left_click=self._toggle_popup,
            on_refresh=self._refresh_now,
            on_quit=self._quit,
            get_refresh_interval=lambda: self._refresh_interval,
            set_refresh_interval=self._set_refresh_interval,
            on_login=self._do_login,
        )

        self._refresh_timer: threading.Timer | None = None

    # ── Startup ────────────────────────────────────────────────────────────────

    def run(self) -> None:
        """Start everything and enter the tkinter main loop."""
        # Wire scraping callbacks
        self._scraper.on_usage_updated = self._on_usage_updated
        self._scraper.on_needs_login   = self._on_needs_login
        self._scraper.on_login_success = self._on_login_success

        # Start background services
        self._scraper.start()
        self._tray.start()
        self._restart_timer()
        self._check_for_updates()

        # tkinter main loop (runs on the main thread)
        self._root.mainloop()

    # ── Callbacks from scraping service ───────────────────────────────────────

    def _on_usage_updated(self, data: UsageData | None) -> None:
        """Called from a background thread; schedule GUI update on main thread."""
        self._root.after(0, lambda: self._handle_usage_update(data))

    def _handle_usage_update(self, data: UsageData | None) -> None:
        """Must run on the main (tkinter) thread."""
        if data is None:
            self._popup.update_display(None, self._scraper.is_loading)
            self._tray.update(None)
            return

        # Detect session reset (pct dropped) → clear history
        if data.session_percentage < (self._usage_history[-1][1] if self._usage_history else 0) - _SESSION_RESET_THRESHOLD:
            self._usage_history.clear()

        # Append current point; keep last 10
        self._usage_history.append((datetime.now(timezone.utc), data.session_percentage))
        if len(self._usage_history) > 10:
            self._usage_history.pop(0)

        # Enrich a local copy
        enriched = UsageData(
            plan_type=data.plan_type,
            messages_used=data.messages_used,
            messages_limit=data.messages_limit,
            session_used=data.session_used,
            session_limit=data.session_limit,
            reset_date=data.reset_date,
            weekly_reset_date=data.weekly_reset_date,
            weekly_reset_text=data.weekly_reset_text,
            rate_limit_status=data.rate_limit_status,
            last_updated=data.last_updated,
            usage_history=list(self._usage_history),
        )

        self._popup.update_display(enriched, self._scraper.is_loading)
        self._tray.update(enriched)
        self._notifications.check_and_notify(enriched)

        if self._available_update:
            self._popup.notify_update(self._available_update)

    def _on_needs_login(self) -> None:
        self._root.after(0, self._present_login_window)

    def _present_login_window(self) -> None:
        """Show the login prompt in the popup and update the tray menu."""
        self._tray.set_needs_login(True)
        self._popup.show_login_required(self._do_login)
        if not self._popup.is_visible:
            self._popup.show()

    def _do_login(self, token: str) -> None:
        """Inject the pasted session token into the running browser context."""
        self._scraper.inject_session_cookie(token)

    def _on_login_success(self) -> None:
        self._root.after(0, self._handle_login_success)

    def _handle_login_success(self) -> None:
        """Called on the main thread after a successful login."""
        self._tray.set_needs_login(False)
        self._popup.update_display(None, True)
        # Bring the popup to the front — the headed browser window was covering it.
        self._popup.show()

    # ── Refresh ────────────────────────────────────────────────────────────────

    def _refresh_now(self) -> None:
        self._scraper.refresh()
        self._popup.update_display(self._scraper.usage_data, True)

    def _set_refresh_interval(self, interval: float) -> None:
        self._refresh_interval = interval
        self._settings["refreshInterval"] = interval
        _save_settings(self._settings)
        self._restart_timer()
        self._tray.update(self._scraper.usage_data)  # redraw menu checkmarks

    def _restart_timer(self) -> None:
        if self._refresh_timer is not None:
            self._refresh_timer.cancel()
        self._refresh_timer = threading.Timer(
            self._refresh_interval, self._timer_tick
        )
        self._refresh_timer.daemon = True
        self._refresh_timer.start()

    def _timer_tick(self) -> None:
        self._scraper.refresh()
        self._restart_timer()

    # ── Popup toggle ───────────────────────────────────────────────────────────

    def _toggle_popup(self) -> None:
        self._root.after(0, self._do_toggle_popup)

    def _do_toggle_popup(self) -> None:
        if self._popup.is_visible:
            self._popup.hide()
        elif self._scraper.needs_login:
            self._present_login_window()
        else:
            # Refresh if data is older than 30 s
            data = self._scraper.usage_data
            if data is None or (datetime.now(timezone.utc) - data.last_updated).total_seconds() > 30:
                self._scraper.refresh()
            self._popup.show()

    # ── Update check ──────────────────────────────────────────────────────────

    def _check_for_updates(self) -> None:
        def _callback(version: str | None) -> None:
            if version:
                self._available_update = version
                self._root.after(0, lambda: self._popup.notify_update(version))

        self._updater.check_for_updates(_callback)

    # ── Quit ──────────────────────────────────────────────────────────────────

    def _quit(self) -> None:
        if self._refresh_timer:
            self._refresh_timer.cancel()
        self._root.after(0, self._root.destroy)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    app = AppController()
    app.run()


if __name__ == "__main__":
    main()
