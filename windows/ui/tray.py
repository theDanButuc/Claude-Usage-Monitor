"""
TrayIcon — port of the NSStatusBar / NSStatusItem portion of AppDelegate.swift

Manages the Windows system-tray icon via pystray.  Left-click toggles the
popup; right-click shows the context menu.
"""

from __future__ import annotations

import threading
from typing import TYPE_CHECKING, Callable

from PIL import Image, ImageDraw, ImageFont

try:
    import pystray
    _PYSTRAY_AVAILABLE = True
except ImportError:
    _PYSTRAY_AVAILABLE = False

if TYPE_CHECKING:
    from models import UsageData

# ── Icon generation ────────────────────────────────────────────────────────────

_GREEN  = (52, 199, 89)
_ORANGE = (255, 149, 0)
_RED    = (255, 59, 48)
_GREY   = (120, 120, 128)
_WHITE  = (255, 255, 255, 255)
_TRANSPARENT = (0, 0, 0, 0)

_ICON_SIZE = 64  # Internal resolution; pystray will scale


def _make_icon_image(color: tuple, label: str = "") -> Image.Image:
    """Generate a small icon image with a coloured circle and optional label."""
    img = Image.new("RGBA", (_ICON_SIZE, _ICON_SIZE), _TRANSPARENT)
    draw = ImageDraw.Draw(img)
    # Draw filled circle
    margin = 6
    draw.ellipse(
        [margin, margin, _ICON_SIZE - margin, _ICON_SIZE - margin],
        fill=(*color, 255),
    )
    return img


def _color_for(data: "UsageData | None", is_stale: bool) -> tuple:
    if is_stale:
        return _GREY
    if data is None:
        return _GREY
    pct = data.usage_percentage
    if pct >= 0.8:
        return _RED
    if pct >= 0.5:
        return _ORANGE
    return _GREEN


# ── TrayIcon ───────────────────────────────────────────────────────────────────

class TrayIcon:
    def __init__(
        self,
        on_left_click: Callable,
        on_refresh: Callable,
        on_quit: Callable,
        get_refresh_interval: Callable[[], float],
        set_refresh_interval: Callable[[float], None],
    ) -> None:
        self._on_left_click = on_left_click
        self._on_refresh = on_refresh
        self._on_quit = on_quit
        self._get_refresh_interval = get_refresh_interval
        self._set_refresh_interval = set_refresh_interval

        self._current_data: "UsageData | None" = None
        self._icon: "pystray.Icon | None" = None

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def start(self) -> None:
        """Start the tray icon on a background daemon thread."""
        if not _PYSTRAY_AVAILABLE:
            return
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self) -> None:
        icon_img = _make_icon_image(_GREY)
        self._icon = pystray.Icon(
            name="ClaudeUsageMonitor",
            icon=icon_img,
            title="Claude Usage Monitor",
            menu=self._build_menu(),
        )

        # pystray on Windows handles left / right click differently.
        # We use the default left-click to open the popup.
        self._icon.run(setup=self._setup)

    def _setup(self, icon: "pystray.Icon") -> None:
        icon.visible = True

    # ── Update ─────────────────────────────────────────────────────────────────

    def update(self, data: "UsageData | None") -> None:
        self._current_data = data
        if self._icon is None:
            return
        is_stale = data.is_stale if data else False
        color = _color_for(data, is_stale)
        self._icon.icon = _make_icon_image(color)
        tooltip = "Claude Usage Monitor"
        if data:
            label = data.menu_bar_label
            stale_note = " · stale" if is_stale else ""
            tooltip = f"Claude Usage Monitor · {label}{stale_note}" if label else tooltip
        self._icon.title = tooltip
        self._icon.menu = self._build_menu()

    # ── Menu ───────────────────────────────────────────────────────────────────

    def _build_menu(self) -> "pystray.Menu":
        if not _PYSTRAY_AVAILABLE:
            return None

        items = []

        data = self._current_data
        if data:
            pct_str = f"{int(data.usage_percentage * 100)}%"
            usage_text = f"{data.primary_used}/{data.primary_limit}  ({pct_str})"
            items.append(pystray.MenuItem(usage_text, None, enabled=False))
            if data.reset_date is not None:
                items.append(pystray.MenuItem(f"Resets in {data.time_until_reset}", None, enabled=False))
            if data.is_stale:
                items.append(pystray.MenuItem("⚠  Data may be stale", None, enabled=False))
        else:
            items.append(pystray.MenuItem("No data yet", None, enabled=False))

        items.append(pystray.Menu.SEPARATOR)

        # Refresh interval submenu
        interval_options = [
            ("30 seconds", 30),
            ("1 minute",   60),
            ("2 minutes",  120),
            ("5 minutes",  300),
            ("10 minutes", 600),
        ]
        current_interval = self._get_refresh_interval()

        def _make_interval_action(interval: float):
            def _action(icon, item):
                self._set_refresh_interval(interval)
            return _action

        interval_items = [
            pystray.MenuItem(
                label,
                _make_interval_action(iv),
                checked=lambda item, iv=iv: abs(self._get_refresh_interval() - iv) < 1,
                radio=True,
            )
            for label, iv in interval_options
        ]
        items.append(pystray.MenuItem("Refresh Interval", pystray.Menu(*interval_items)))

        items.append(pystray.Menu.SEPARATOR)

        def _refresh_now(icon, item):
            self._on_refresh()

        items.append(pystray.MenuItem("Refresh Now", _refresh_now))
        items.append(pystray.Menu.SEPARATOR)

        def _open_popup(icon, item):
            self._on_left_click()

        items.append(pystray.MenuItem("Show Usage", _open_popup, default=True))
        items.append(pystray.Menu.SEPARATOR)

        def _quit(icon, item):
            icon.stop()
            self._on_quit()

        items.append(pystray.MenuItem("Quit", _quit))

        return pystray.Menu(*items)

    def stop(self) -> None:
        if self._icon:
            self._icon.stop()
