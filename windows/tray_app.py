"""Main entry point: system tray app showing Claude Code usage limits."""

import sys
import os
import threading

# Add project root to path so we can run as `pythonw tray_app.py`
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import customtkinter as ctk
import pystray
from pystray import MenuItem

from constants import POLL_INTERVAL_MS
from data_reader import RateLimitData, read_rate_limits
from icon_generator import create_icon
from popup_window import UsagePopup

SCRAPE_OPTIONS = [
    ("30 seconds", 30_000),
    ("1 minute", 60_000),
    ("2 minutes", 120_000),
    ("5 minutes", 300_000),
    ("10 minutes", 600_000),
]
DEFAULT_SCRAPE_INDEX = 2  # 2 minutes


class ClaudeUsageTray:
    """Orchestrates the system tray icon, polling, and popup window."""

    def __init__(self):
        self._data: RateLimitData = read_rate_limits()
        self._popup: UsagePopup | None = None
        self._icon: pystray.Icon | None = None
        self._scrape_index = DEFAULT_SCRAPE_INDEX
        self._scrape_interval = SCRAPE_OPTIONS[DEFAULT_SCRAPE_INDEX][1]

        # Set up customtkinter
        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("dark-blue")

        # Hidden root window (drives mainloop, never shown)
        self._root = ctk.CTk()
        self._root.withdraw()
        self._root.title("Claude Usage Tray")

        # Prevent the root from appearing in taskbar
        self._root.attributes("-alpha", 0)

        self._scraping = False

        # Build tray icon
        self._build_tray()

        # Start polling file
        self._root.after(POLL_INTERVAL_MS, self._poll)

        # Initial scrape in background
        self._schedule_scrape(delay=2000)

    def _build_tray(self):
        """Create and start the pystray icon in a daemon thread."""
        pct = None
        if self._data.five_hour:
            pct = self._data.five_hour.used_percentage

        image = create_icon(pct)
        tooltip = self._build_tooltip()

        menu = pystray.Menu(
            MenuItem("Show Usage", self._on_show, default=True),
            MenuItem("Refresh Now", self._on_refresh),
            MenuItem(
                "Poll Frequency",
                pystray.Menu(
                    *[
                        MenuItem(
                            label,
                            self._make_freq_handler(i),
                            checked=lambda item, idx=i: self._scrape_index == idx,
                            radio=True,
                        )
                        for i, (label, _ms) in enumerate(SCRAPE_OPTIONS)
                    ]
                ),
            ),
            pystray.Menu.SEPARATOR,
            MenuItem("Quit", self._on_quit),
        )

        self._icon = pystray.Icon(
            "claude-usage",
            image,
            tooltip,
            menu,
        )

        # Run pystray in daemon thread
        thread = threading.Thread(target=self._icon.run, daemon=True)
        thread.start()

    def _build_tooltip(self) -> str:
        """Build tooltip text from current data."""
        parts = ["Claude Code Usage"]
        if self._data.five_hour and self._data.five_hour.used_percentage is not None:
            parts.append(f"5h: {self._data.five_hour.used_percentage:.0f}%")
        if self._data.seven_day and self._data.seven_day.used_percentage is not None:
            parts.append(f"7d: {self._data.seven_day.used_percentage:.0f}%")
        if self._data.sonnet and self._data.sonnet.used_percentage is not None:
            parts.append(f"Sonnet: {self._data.sonnet.used_percentage:.0f}%")
        if not self._data.file_exists:
            parts.append("No data yet")
        return " | ".join(parts)

    def _poll(self):
        """Poll the rate-limits.json file for updates."""
        new_data = read_rate_limits()

        if self._data_changed(new_data):
            self._data = new_data
            self._update_icon()
            if self._popup is not None and self._popup.winfo_exists():
                self._popup.update_data(self._data)

        # Reschedule
        self._root.after(POLL_INTERVAL_MS, self._poll)

    def _data_changed(self, new: RateLimitData) -> bool:
        """Check if data has meaningfully changed."""
        old = self._data
        if old.file_exists != new.file_exists:
            return True
        if old.last_updated != new.last_updated:
            return True
        return False

    def _update_icon(self):
        """Update the tray icon image and tooltip."""
        if self._icon is None:
            return

        pct = None
        if self._data.five_hour:
            pct = self._data.five_hour.used_percentage

        self._icon.icon = create_icon(pct)
        self._icon.title = self._build_tooltip()

    def _on_show(self, icon=None, item=None):
        """Show/toggle the popup — marshalled to main thread."""
        self._root.after(0, self._toggle_popup)

    def _on_refresh(self, icon=None, item=None):
        """Force refresh by scraping claude.ai."""
        self._root.after(0, lambda: self._schedule_scrape(delay=0))

    def _make_freq_handler(self, index):
        """Return a handler that sets the scrape frequency."""
        def handler(icon=None, item=None):
            self._scrape_index = index
            self._scrape_interval = SCRAPE_OPTIONS[index][1]
            print(f"[tray] Poll frequency: {SCRAPE_OPTIONS[index][0]}")
        return handler

    def _on_quit(self, icon=None, item=None):
        """Quit the application."""
        if self._icon:
            self._icon.stop()
        self._root.after(0, self._root.destroy)

    def _toggle_popup(self):
        """Toggle the popup window on/off."""
        if self._popup is not None:
            try:
                if self._popup.winfo_exists():
                    self._popup.destroy()
                    self._popup = None
                    return
            except Exception:
                pass
            self._popup = None

        # Re-read data for freshest resets_in
        self._data = read_rate_limits()
        self._popup = UsagePopup(self._root, self._data, on_refresh=self._popup_refresh)
        # Track destruction
        self._popup.bind("<Destroy>", self._on_popup_destroy)

    def _on_popup_destroy(self, event):
        """Clean up popup reference when it's destroyed."""
        if event.widget == self._popup:
            self._popup = None

    def _popup_refresh(self):
        """Called when the Refresh button in the popup is clicked."""
        self._schedule_scrape(delay=0)

    def _force_refresh(self):
        """Force a data refresh and update everything."""
        self._data = read_rate_limits()
        self._update_icon()
        if self._popup is not None and self._popup.winfo_exists():
            self._popup.update_data(self._data)

    def _schedule_scrape(self, delay=None):
        """Schedule a background scrape of claude.ai."""
        if delay is None:
            delay = self._scrape_interval
        self._root.after(delay, self._run_scrape)

    def _run_scrape(self):
        """Run the scraper in a background thread."""
        if self._scraping:
            self._schedule_scrape()
            return
        self._scraping = True
        thread = threading.Thread(target=self._scrape_worker, daemon=True)
        thread.start()

    def _scrape_worker(self):
        """Background thread: scrape claude.ai and update data."""
        try:
            from scraper import scrape_usage
            scrape_usage()
        except Exception as e:
            print(f"Scrape failed: {e}")
        finally:
            self._scraping = False
            # Re-read the file (scraper writes to it) and schedule next scrape
            self._root.after(0, self._force_refresh)
            self._root.after(0, lambda: self._schedule_scrape())

    def run(self):
        """Start the application mainloop."""
        self._root.mainloop()


def main():
    app = ClaudeUsageTray()
    app.run()


if __name__ == "__main__":
    main()