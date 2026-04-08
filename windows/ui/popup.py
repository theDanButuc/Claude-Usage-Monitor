"""
PopupWindow — port of ContentView.swift + AppDelegate popover

A tkinter Toplevel that shows the two-bar usage dashboard.
It is created once and hidden/shown as needed (like NSPopover).
"""

from __future__ import annotations

import subprocess
import sys
import threading
import tkinter as tk
import webbrowser
from tkinter import font as tkfont
from tkinter import ttk
from typing import TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from models import UsageData

# ── Colour palette ─────────────────────────────────────────────────────────────

_BG = "#1e1e1e"
_CARD = "#2a2a2a"
_TEXT_PRIMARY = "#e8e8e8"
_TEXT_SECONDARY = "#888888"
_TEXT_TERTIARY = "#555555"
_ACCENT = "#7c6aff"  # purple-ish, similar to Claude brand
_SEP = "#333333"

_GREEN = "#34c759"
_ORANGE = "#ff9500"
_RED = "#ff3b30"
_BLUE = "#0a84ff"


def _bar_color(progress: float) -> str:
    if progress >= 0.8:
        return _RED
    if progress >= 0.5:
        return _ORANGE
    return _GREEN


# ── Canvas-based progress bar ──────────────────────────────────────────────────

class ProgressBar(tk.Canvas):
    """A simple rounded-rect progress bar drawn on a Canvas."""

    def __init__(self, parent, height: int = 8, **kwargs):
        super().__init__(parent, height=height, bg=_CARD, highlightthickness=0, **kwargs)
        self._progress = 0.0
        self._color = _GREEN
        self.bind("<Configure>", lambda _e: self._draw())

    def set_progress(self, value: float, color: str | None = None) -> None:
        self._progress = max(0.0, min(1.0, value))
        self._color = color or _bar_color(self._progress)
        self._draw()

    def _draw(self) -> None:
        self.delete("all")
        w = self.winfo_width()
        h = self.winfo_height()
        if w <= 1:
            return
        r = h // 2
        # Track
        self._rounded_rect(0, 0, w, h, r, fill="#3a3a3a")
        # Fill
        filled_w = max(h, int(w * self._progress))
        self._rounded_rect(0, 0, filled_w, h, r, fill=self._color)

    def _rounded_rect(self, x1, y1, x2, y2, r, **kwargs) -> None:
        self.create_arc(x1, y1, x1 + 2*r, y1 + 2*r, start=90,  extent=90,  style="pieslice", outline="", **kwargs)
        self.create_arc(x2 - 2*r, y1, x2, y1 + 2*r, start=0,   extent=90,  style="pieslice", outline="", **kwargs)
        self.create_arc(x1, y2 - 2*r, x1 + 2*r, y2, start=180, extent=90,  style="pieslice", outline="", **kwargs)
        self.create_arc(x2 - 2*r, y2 - 2*r, x2, y2, start=270, extent=90,  style="pieslice", outline="", **kwargs)
        self.create_rectangle(x1 + r, y1, x2 - r, y2, outline="", **kwargs)
        self.create_rectangle(x1, y1 + r, x2, y2 - r, outline="", **kwargs)


# ── Main popup window ──────────────────────────────────────────────────────────

class PopupWindow:
    WIDTH = 320

    def __init__(self, root: tk.Tk, on_refresh: Callable, on_quit: Callable) -> None:
        self._root = root
        self._on_refresh = on_refresh
        self._on_quit = on_quit
        self._visible = False
        self._available_update: str | None = None

        self._win = tk.Toplevel(root)
        self._win.title("Claude Usage Monitor")
        self._win.configure(bg=_SEP)   # 1 px border colour
        self._win.resizable(False, False)
        self._win.overrideredirect(True)   # borderless popover — no OS title bar
        self._win.withdraw()  # start hidden

        # Keep on top so it behaves like a popover
        self._win.attributes("-topmost", True)

        # Drag state (header drag lets the user reposition the popup)
        self._drag_x = 0
        self._drag_y = 0

        self._build_ui()

    # ── Build ──────────────────────────────────────────────────────────────────

    def _build_ui(self) -> None:
        # 1 px border is provided by the window's bg=_SEP + 1 px padding here
        self._frame = tk.Frame(self._win, bg=_BG, padx=0, pady=0)
        self._frame.pack(fill="both", expand=True, padx=1, pady=1)

        self._build_header()
        self._sep(self._frame)
        self._build_content()
        self._sep(self._frame)
        self._build_footer()

    def _build_header(self) -> None:
        hdr = tk.Frame(self._frame, bg="#252525", padx=16, pady=10)
        hdr.pack(fill="x")

        # Make header draggable so the user can reposition the popup
        hdr.bind("<ButtonPress-1>", self._start_drag)
        hdr.bind("<B1-Motion>", self._do_drag)

        tk.Label(
            hdr,
            text="Claude Usage",
            bg="#252525",
            fg=_TEXT_PRIMARY,
            font=("Segoe UI", 12, "bold"),
        ).pack(side="left")

        self._plan_badge = tk.Label(hdr, text="", bg="#252525", fg=_TEXT_SECONDARY,
                                    font=("Segoe UI", 9))
        self._plan_badge.pack(side="left", padx=(6, 0))

        # ✕ button hides the popup (does not quit the app)
        close_btn = tk.Label(
            hdr, text="✕", bg="#252525", fg=_TEXT_SECONDARY,
            font=("Segoe UI", 10), cursor="hand2",
        )
        close_btn.pack(side="right")
        close_btn.bind("<Button-1>", lambda _: self.hide())
        close_btn.bind("<Enter>", lambda _: close_btn.config(fg=_TEXT_PRIMARY))
        close_btn.bind("<Leave>", lambda _: close_btn.config(fg=_TEXT_SECONDARY))

        # Update banner (hidden by default)
        self._update_frame = tk.Frame(self._frame, bg="#0d2137", padx=12, pady=6)
        self._update_label = tk.Label(
            self._update_frame, text="", bg="#0d2137", fg=_BLUE,
            font=("Segoe UI", 10), cursor="hand2"
        )
        self._update_label.pack(side="left")
        self._update_label.bind("<Button-1>", self._open_release)

        dismiss_btn = tk.Label(
            self._update_frame, text="✕", bg="#0d2137", fg=_TEXT_SECONDARY,
            font=("Segoe UI", 9), cursor="hand2"
        )
        dismiss_btn.pack(side="right")
        dismiss_btn.bind("<Button-1>", lambda _: self._dismiss_update())

    def _build_content(self) -> None:
        self._content = tk.Frame(self._frame, bg=_BG, padx=16, pady=12)
        self._content.pack(fill="x")

        # Loading / error placeholders
        self._loading_label = tk.Label(
            self._content, text="Loading usage data…", bg=_BG,
            fg=_TEXT_SECONDARY, font=("Segoe UI", 10)
        )

        self._error_frame = tk.Frame(self._content, bg=_BG)
        self._error_label = tk.Label(
            self._error_frame, text="", bg=_BG, fg=_ORANGE,
            font=("Segoe UI", 10), wraplength=self.WIDTH - 40, justify="center"
        )
        self._error_label.pack()
        tk.Button(
            self._error_frame, text="Try Again", command=self._on_refresh,
            bg=_CARD, fg=_TEXT_PRIMARY, relief="flat", font=("Segoe UI", 9),
            padx=8, pady=4
        ).pack(pady=(6, 0))

        # Stale banner
        self._stale_frame = tk.Frame(self._content, bg="#2a1e00", padx=8, pady=6)
        tk.Label(
            self._stale_frame, text="⚠ Data may be outdated", bg="#2a1e00",
            fg=_ORANGE, font=("Segoe UI", 9)
        ).pack(side="left")
        tk.Button(
            self._stale_frame, text="Refresh", command=self._on_refresh,
            bg="#2a1e00", fg=_ORANGE, relief="flat", font=("Segoe UI", 9),
            cursor="hand2"
        ).pack(side="right")

        # Login required frame
        self._login_frame = tk.Frame(self._content, bg=_BG)
        tk.Label(
            self._login_frame,
            text="Sign in to Claude to view your usage stats.",
            bg=_BG, fg=_TEXT_SECONDARY, font=("Segoe UI", 10),
            wraplength=self.WIDTH - 40, justify="center",
        ).pack(pady=(12, 8))
        self._login_btn = tk.Button(
            self._login_frame, text="Sign In",
            bg=_ACCENT, fg="#ffffff", relief="flat",
            font=("Segoe UI", 10, "bold"), padx=16, pady=6, cursor="hand2",
        )
        self._login_btn.pack(pady=(0, 12))

        # Tips area
        self._tips_frame = tk.Frame(self._content, bg=_BG)
        self._tips_frame.pack(fill="x", pady=(0, 8))

        # Usage bars card
        card = tk.Frame(self._content, bg=_CARD, padx=14, pady=12)
        card.pack(fill="x")

        tk.Label(
            card, text="Plan usage limits", bg=_CARD, fg=_TEXT_PRIMARY,
            font=("Segoe UI", 11, "bold")
        ).pack(anchor="w", pady=(0, 10))

        # Session bar
        self._session_title = tk.Label(card, text="Current session", bg=_CARD,
                                        fg=_TEXT_PRIMARY, font=("Segoe UI", 10, "bold"))
        self._session_title.pack(anchor="w")
        self._session_reset_label = tk.Label(card, text="", bg=_CARD,
                                              fg=_TEXT_SECONDARY, font=("Segoe UI", 9))
        self._session_reset_label.pack(anchor="w")
        self._session_pct_label = tk.Label(card, text="", bg=_CARD,
                                            fg=_TEXT_SECONDARY, font=("Segoe UI", 9))
        self._session_pct_label.pack(anchor="e")
        self._session_bar = ProgressBar(card, height=8)
        self._session_bar.pack(fill="x", pady=(4, 8))

        tk.Frame(card, bg=_SEP, height=1).pack(fill="x", pady=4)

        # Weekly bar
        tk.Label(card, text="Weekly limits", bg=_CARD, fg=_TEXT_SECONDARY,
                 font=("Segoe UI", 9, "bold")).pack(anchor="w", pady=(4, 4))
        self._weekly_title = tk.Label(card, text="All models", bg=_CARD,
                                       fg=_TEXT_PRIMARY, font=("Segoe UI", 10, "bold"))
        self._weekly_title.pack(anchor="w")
        self._weekly_reset_label = tk.Label(card, text="", bg=_CARD,
                                             fg=_TEXT_SECONDARY, font=("Segoe UI", 9))
        self._weekly_reset_label.pack(anchor="w")
        self._weekly_pct_label = tk.Label(card, text="", bg=_CARD,
                                           fg=_TEXT_SECONDARY, font=("Segoe UI", 9))
        self._weekly_pct_label.pack(anchor="e")
        self._weekly_bar = ProgressBar(card, height=8)
        self._weekly_bar.pack(fill="x", pady=(4, 4))

        # Spinner overlay (shown during refresh)
        self._spinner_label = tk.Label(card, text="", bg=_CARD, fg=_TEXT_SECONDARY,
                                        font=("Segoe UI", 9))
        self._spinner_label.pack(anchor="e", pady=(2, 0))

    def _build_footer(self) -> None:
        ftr = tk.Frame(self._frame, bg=_BG, padx=14, pady=8)
        ftr.pack(fill="x")

        self._last_updated_label = tk.Label(
            ftr, text="Not yet updated", bg=_BG, fg=_TEXT_TERTIARY,
            font=("Segoe UI", 8)
        )
        self._last_updated_label.pack(side="left")

        tk.Button(
            ftr, text="✕ Quit", command=self._on_quit,
            bg=_BG, fg=_TEXT_SECONDARY, relief="flat", font=("Segoe UI", 9),
            cursor="hand2", activebackground=_CARD
        ).pack(side="right", padx=(6, 0))

        self._refresh_btn = tk.Button(
            ftr, text="↻", command=self._on_refresh,
            bg=_BG, fg=_TEXT_SECONDARY, relief="flat", font=("Segoe UI", 11),
            cursor="hand2", activebackground=_CARD
        )
        self._refresh_btn.pack(side="right")

    def _sep(self, parent) -> None:
        tk.Frame(parent, bg=_SEP, height=1).pack(fill="x")

    # ── Public API ─────────────────────────────────────────────────────────────

    def show(self, x: int | None = None, y: int | None = None) -> None:
        # Show first so geometry is measurable
        self._win.deiconify()
        self._win.update_idletasks()

        if x is not None and y is not None:
            # Caller supplied explicit coordinates (e.g. from a cursor position)
            screen_h = self._win.winfo_screenheight()
            win_h = self._win.winfo_height() or 460
            actual_y = y - win_h if y > screen_h // 2 else y
            self._win.geometry(f"+{x}+{actual_y}")
        else:
            # Auto-position in the bottom-right corner above the taskbar
            w = self._win.winfo_width() or self.WIDTH
            h = self._win.winfo_height() or 460
            screen_w = self._win.winfo_screenwidth()
            screen_h = self._win.winfo_screenheight()
            margin = 12
            taskbar_h = 48  # typical Windows taskbar height
            pos_x = screen_w - w - margin
            pos_y = screen_h - h - taskbar_h - margin
            self._win.geometry(f"+{pos_x}+{pos_y}")

        self._win.lift()
        self._win.focus_force()
        self._visible = True
        # Arm focus-out dismiss after a short delay to avoid a false trigger on open
        self._win.after(250, lambda: self._win.bind("<FocusOut>", self._on_focus_out))

    def hide(self) -> None:
        self._win.unbind("<FocusOut>")
        self._win.withdraw()
        self._visible = False

    def toggle(self, x: int | None = None, y: int | None = None) -> None:
        if self._visible:
            self.hide()
        else:
            self.show(x, y)

    @property
    def is_visible(self) -> bool:
        return self._visible

    # ── Drag support ───────────────────────────────────────────────────────────

    def _start_drag(self, event: tk.Event) -> None:
        self._drag_x = event.x_root - self._win.winfo_x()
        self._drag_y = event.y_root - self._win.winfo_y()

    def _do_drag(self, event: tk.Event) -> None:
        x = event.x_root - self._drag_x
        y = event.y_root - self._drag_y
        self._win.geometry(f"+{x}+{y}")

    # ── Focus-out dismiss ──────────────────────────────────────────────────────

    def _on_focus_out(self, event: tk.Event) -> None:
        # Small delay lets tkinter settle the new focus target before we check
        self._win.after(150, self._check_and_hide)

    def _check_and_hide(self) -> None:
        if not self._visible:
            return
        try:
            focused = self._win.focus_get()
        except Exception:
            focused = None
        if focused is None:
            self.hide()

    def notify_update(self, version: str) -> None:
        self._available_update = version
        self._update_label.config(text=f"v{version} available — View Release")
        self._update_frame.pack(fill="x", after=self._frame.winfo_children()[0])

    def show_login_required(self, on_login: Callable) -> None:
        """Replace the content area with a sign-in prompt."""
        for w in self._tips_frame.winfo_children():
            w.destroy()
        self._loading_label.pack_forget()
        self._error_frame.pack_forget()
        self._stale_frame.pack_forget()
        self._login_btn.config(command=on_login)
        self._login_frame.pack(pady=24)

    def update_display(self, data: "UsageData | None", is_loading: bool) -> None:
        """Refresh all widgets with the latest data. Must be called on the main thread."""
        # Clear dynamic children
        for w in self._tips_frame.winfo_children():
            w.destroy()
        self._loading_label.pack_forget()
        self._error_frame.pack_forget()
        self._login_frame.pack_forget()
        self._stale_frame.pack_forget()
        self._spinner_label.config(text="↻ refreshing…" if is_loading else "")

        if is_loading and data is None:
            self._loading_label.pack(pady=24)
            return

        if data is None:
            return

        # Stale banner
        if data.is_stale:
            self._stale_frame.pack(fill="x", pady=(0, 8))

        # Tips
        for tip in data.current_tips:
            tip_row = tk.Frame(self._tips_frame, bg=_BG)
            tip_row.pack(fill="x", pady=(0, 4))
            tk.Label(tip_row, text=tip.icon, bg=_BG, fg=_TEXT_PRIMARY,
                     font=("Segoe UI", 11)).pack(side="left", padx=(0, 6))
            tk.Label(tip_row, text=tip.message, bg=_BG, fg=_TEXT_SECONDARY,
                     font=("Segoe UI", 9), wraplength=self.WIDTH - 60,
                     justify="left").pack(side="left")
            for action in tip.actions:
                btn = tk.Button(
                    self._tips_frame,
                    text=f"Copy: {action.label}",
                    command=lambda ct=action.copy_text: self._copy_to_clipboard(ct),
                    bg=_CARD, fg=_TEXT_PRIMARY, relief="flat",
                    font=("Segoe UI", 8), padx=6, pady=2
                )
                btn.pack(anchor="w", padx=(24, 0), pady=(1, 0))

        # Plan badge
        self._plan_badge.config(text=data.plan_type if data.plan_type != "Unknown" else "")

        # Session bar
        if data.has_session_data:
            self._session_bar.set_progress(data.session_percentage)
            self._session_pct_label.config(
                text=f"{int(data.session_percentage * 100)}% used"
            )
            self._session_reset_label.config(
                text=data.session_reset_label or ""
            )
        else:
            self._session_bar.set_progress(0, _TEXT_SECONDARY)
            self._session_pct_label.config(text="")
            self._session_reset_label.config(text="No data")

        # Weekly bar
        if data.messages_limit > 0:
            self._weekly_bar.set_progress(data.weekly_percentage)
            self._weekly_pct_label.config(
                text=f"{int(data.weekly_percentage * 100)}% used"
            )
            self._weekly_reset_label.config(
                text=data.weekly_reset_label or ""
            )
        else:
            self._weekly_bar.set_progress(0, _TEXT_SECONDARY)
            self._weekly_pct_label.config(text="")
            self._weekly_reset_label.config(text="No data")

        # Last updated
        self._last_updated_label.config(
            text=f"Updated {data.last_updated_formatted}"
        )

    def show_error(self, message: str) -> None:
        self._error_label.config(text=message)
        self._error_frame.pack(pady=24)

    # ── Helpers ────────────────────────────────────────────────────────────────

    def _copy_to_clipboard(self, text: str) -> None:
        self._win.clipboard_clear()
        self._win.clipboard_append(text)

    def _open_release(self, _event=None) -> None:
        webbrowser.open("https://github.com/theDanButuc/Claude-Usage-Monitor/releases/latest")
        self._dismiss_update()

    def _dismiss_update(self) -> None:
        self._available_update = None
        self._update_frame.pack_forget()
