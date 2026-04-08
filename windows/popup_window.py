"""Dark-themed popup window showing Claude Code usage limits."""

import ctypes
import tkinter as tk
from datetime import datetime, timezone
import customtkinter as ctk

from constants import (
    ACCENT,
    BG_COLOR,
    BORDER_COLOR,
    CARD_BG,
    CLAUDE_ORANGE,
    RED,
    TASKBAR_OFFSET,
    TEXT_PRIMARY,
    TEXT_SECONDARY,
    TEXT_TITLE,
    WINDOW_HEIGHT,
    WINDOW_WIDTH,
    usage_color,
)
from data_reader import RateLimitData
from tips import get_tips


def _apply_rounded_corners(hwnd):
    try:
        dwmapi = ctypes.windll.dwmapi
        preference = ctypes.c_int(2)  # DWMWCP_ROUND
        dwmapi.DwmSetWindowAttribute(hwnd, 33, ctypes.byref(preference), ctypes.sizeof(preference))
    except Exception:
        pass


def _apply_dark_title_bar(hwnd):
    try:
        dwmapi = ctypes.windll.dwmapi
        value = ctypes.c_int(1)
        dwmapi.DwmSetWindowAttribute(hwnd, 20, ctypes.byref(value), ctypes.sizeof(value))
    except Exception:
        pass


class UsagePopup(ctk.CTkToplevel):

    def __init__(self, parent, data: RateLimitData, on_refresh=None):
        super().__init__(parent)
        self._on_refresh = on_refresh
        self._refreshing = False

        self.title("Claude Code Usage")
        self.configure(fg_color=BG_COLOR)
        self.resizable(False, False)
        self.attributes("-topmost", True)
        self.overrideredirect(True)

        screen_w = self.winfo_screenwidth()
        screen_h = self.winfo_screenheight()
        self.geometry(f"{WINDOW_WIDTH}x1")  # width fixed, height auto
        self._screen_w = screen_w
        self._screen_h = screen_h

        self._drag_start_x = 0
        self._drag_start_y = 0

        self.bind("<Escape>", lambda e: self.destroy())

        # Store references to updatable widgets
        self._fh_widgets = None  # (pct_label, budget_bar, usage_bar, over_bar, reset_label)
        self._sd_widgets = None
        self._sn_widgets = None
        self._updated_label = None
        self._refresh_btn = None
        self._tips_frame = None
        self._tips_main = None  # reference to main container for geometry updates
        self._tips_visible = True
        self._tips_pct: float | None = None

        self._build_ui(data)

        # Let tkinter calculate the natural height, then position
        self.update_idletasks()
        natural_h = self.winfo_reqheight()
        x = self._screen_w - WINDOW_WIDTH - TASKBAR_OFFSET
        y = self._screen_h - natural_h - 50
        self.geometry(f"{WINDOW_WIDTH}x{natural_h}+{x}+{y}")

        hwnd = ctypes.windll.user32.GetParent(self.winfo_id())
        _apply_rounded_corners(hwnd)
        _apply_dark_title_bar(hwnd)

        self.after(50, self._grab_focus)

    def _grab_focus(self):
        self.focus_force()
        self.lift()

    def _start_drag(self, event):
        self._drag_start_x = event.x_root
        self._drag_start_y = event.y_root
        self._win_start_x = self.winfo_x()
        self._win_start_y = self.winfo_y()

    def _do_drag(self, event):
        dx = event.x_root - self._drag_start_x
        dy = event.y_root - self._drag_start_y
        self.geometry(f"+{self._win_start_x + dx}+{self._win_start_y + dy}")

    def _make_draggable(self, widget):
        widget.bind("<Button-1>", self._start_drag)
        widget.bind("<B1-Motion>", self._do_drag)

    def _build_ui(self, data: RateLimitData):
        main = ctk.CTkFrame(self, fg_color=BG_COLOR, corner_radius=0)
        main.pack(fill="both", expand=True)
        self._tips_main = main

        # Title bar
        title_frame = ctk.CTkFrame(main, fg_color=BG_COLOR, height=40, corner_radius=0)
        title_frame.pack(fill="x", padx=16, pady=(12, 0))
        title_frame.pack_propagate(False)
        self._make_draggable(title_frame)

        title_label = ctk.CTkLabel(
            title_frame, text="Claude Code Usage",
            font=("Segoe UI", 16, "bold"), text_color=TEXT_TITLE,
        )
        title_label.pack(side="left")
        self._make_draggable(title_label)

        ctk.CTkButton(
            title_frame, text="x", width=28, height=28, corner_radius=14,
            fg_color="transparent", hover_color="#444444",
            text_color=TEXT_SECONDARY, font=("Segoe UI", 14),
            command=self.destroy,
        ).pack(side="right")

        ctk.CTkFrame(main, fg_color=BORDER_COLOR, height=1).pack(fill="x", padx=16, pady=(8, 0))

        # 5-Hour section (total window = 5 hours)
        self._fh_widgets = self._build_limit_section(main, "5-Hour Limit", data.five_hour, 5 * 3600)

        # Weekly section (total window = 7 days)
        self._sd_widgets = self._build_limit_section(main, "Weekly Limit (7-day)", data.seven_day, 7 * 86400)

        # Sonnet section (same 7-day window) — only shown when data exists
        if data.sonnet is not None and data.sonnet.resets_at is not None:
            self._sn_widgets = self._build_limit_section(main, "Sonnet Only (7-day)", data.sonnet, 7 * 86400)

        # Tips section
        pct = data.five_hour.used_percentage if data.five_hour else None
        self._tips_frame = ctk.CTkFrame(main, fg_color=BG_COLOR, corner_radius=0)
        self._tips_frame.pack(fill="x")
        self._build_tips(self._tips_frame, pct)

        # Footer
        footer = ctk.CTkFrame(main, fg_color=BG_COLOR)
        footer.pack(fill="x", padx=16, pady=(12, 20))

        self._updated_label = ctk.CTkLabel(
            footer, text=self._format_updated(data),
            font=("Segoe UI", 11), text_color=TEXT_SECONDARY,
        )
        self._updated_label.pack(side="left", anchor="center")

        if self._on_refresh:
            self._refresh_btn = ctk.CTkButton(
                footer, text="Refresh", width=70, height=28, corner_radius=6,
                fg_color=ACCENT, hover_color="#666666",
                text_color="#ffffff", font=("Segoe UI", 12),
                command=self._do_refresh,
            )
            self._refresh_btn.pack(side="right", anchor="center")

    def _calc_budget_pct(self, window, total_seconds):
        """Calculate the budget pace percentage (how much of the window has elapsed)."""
        if not window or not window.resets_at:
            return None
        now = datetime.now(timezone.utc)
        remaining = (window.resets_at - now).total_seconds()
        remaining = max(0, remaining)
        elapsed = total_seconds - remaining
        if total_seconds <= 0:
            return None
        return max(0, min(100, (elapsed / total_seconds) * 100))

    def _build_limit_section(self, parent, title, window, total_seconds):
        """Build a section. Returns (pct_label, budget_bar, usage_bar, over_bar, reset_label)."""
        card = ctk.CTkFrame(parent, fg_color=CARD_BG, corner_radius=8)
        card.pack(fill="x", padx=16, pady=(12, 0))

        inner = ctk.CTkFrame(card, fg_color=CARD_BG)
        inner.pack(fill="x", padx=14, pady=12)

        header = ctk.CTkFrame(inner, fg_color=CARD_BG)
        header.pack(fill="x")

        ctk.CTkLabel(
            header, text=title,
            font=("Segoe UI", 13, "bold"), text_color=TEXT_PRIMARY,
        ).pack(side="left")

        pct = window.used_percentage if window else None
        pct_text = f"{pct:.0f}%" if pct is not None else "N/A"
        color = usage_color(pct)

        pct_label = ctk.CTkLabel(
            header, text=pct_text,
            font=("Segoe UI", 13, "bold"), text_color=color,
        )
        pct_label.pack(side="right")

        # Canvas-based progress bar with proper rounded ends
        bar_height = 14
        radius = 7
        canvas = tk.Canvas(inner, height=bar_height + 2, bg=self._hex(CARD_BG),
                           highlightthickness=0, bd=0)
        canvas.pack(fill="x", pady=(8, 6))
        canvas.update_idletasks()

        budget_pct_val = self._calc_budget_pct(window, total_seconds)
        usage_pct_val = pct if pct is not None else 0
        budget_w, usage_w, over_x, over_w = self._calc_bar_widths(usage_pct_val, budget_pct_val)

        # Store canvas + values for updates
        canvas._bar_radius = radius
        canvas._bar_height = bar_height

        self._draw_bars(canvas, bar_height, radius, budget_w, usage_w, over_x, over_w)

        # Redraw on resize
        canvas.bind("<Configure>", lambda e, c=canvas, bw=budget_w, uw=usage_w, ox=over_x, ow=over_w:
                     self._draw_bars(c, bar_height, radius, bw, uw, ox, ow))

        reset_text = f"Resets in {window.resets_in}" if window else "No data available"
        reset_label = ctk.CTkLabel(
            inner, text=reset_text,
            font=("Segoe UI", 11), text_color=TEXT_SECONDARY,
        )
        reset_label.pack(anchor="w")

        return pct_label, canvas, None, None, reset_label

    def _build_tips(self, container, pct):
        """Populate the tips container. Destroys existing children first."""
        for child in container.winfo_children():
            child.destroy()

        tips = get_tips(pct)
        if not tips:
            self._tips_pct = pct
            return

        self._tips_pct = pct

        # Section divider
        ctk.CTkFrame(container, fg_color=BORDER_COLOR, height=1).pack(fill="x", padx=16, pady=(12, 0))

        # Header row with toggle
        header = ctk.CTkFrame(container, fg_color=BG_COLOR)
        header.pack(fill="x", padx=16, pady=(8, 0))

        ctk.CTkLabel(
            header, text="Tips",
            font=("Segoe UI", 12, "bold"), text_color=TEXT_SECONDARY,
        ).pack(side="left")

        toggle_text = "▲" if self._tips_visible else "▼"
        toggle_btn = ctk.CTkButton(
            header, text=toggle_text, width=24, height=20, corner_radius=4,
            fg_color="transparent", hover_color="#333333",
            text_color=TEXT_SECONDARY, font=("Segoe UI", 10),
            command=self._toggle_tips,
        )
        toggle_btn.pack(side="right")

        if not self._tips_visible:
            return

        for tip in tips:
            card = ctk.CTkFrame(container, fg_color=CARD_BG, corner_radius=8,
                                border_width=1, border_color="#4a3020")
            card.pack(fill="x", padx=16, pady=(6, 0))

            inner = ctk.CTkFrame(card, fg_color=CARD_BG)
            inner.pack(fill="x", padx=12, pady=10)

            # Icon + message row
            row = ctk.CTkFrame(inner, fg_color=CARD_BG)
            row.pack(fill="x")

            ctk.CTkLabel(
                row, text=tip.icon, width=20,
                font=("Segoe UI", 13), text_color=CLAUDE_ORANGE,
                anchor="center",
            ).pack(side="left", anchor="n", padx=(0, 6))

            ctk.CTkLabel(
                row, text=tip.message,
                font=("Segoe UI", 11), text_color=TEXT_PRIMARY,
                wraplength=WINDOW_WIDTH - 80, justify="left", anchor="w",
            ).pack(side="left", fill="x", expand=True)

            # Action copy buttons
            if tip.actions:
                btn_row = ctk.CTkFrame(inner, fg_color=CARD_BG)
                btn_row.pack(anchor="w", pady=(6, 0), padx=(26, 0))
                for action in tip.actions:
                    self._make_copy_button(btn_row, action.label, action.copy_text)

    def _make_copy_button(self, parent, label: str, copy_text: str):
        """Create a copy-to-clipboard button that briefly shows 'Copied!'."""
        btn = ctk.CTkButton(
            parent, text=f"Copy: {label}", height=24, corner_radius=4,
            fg_color="#3a2a1a", hover_color="#4a3828",
            text_color=CLAUDE_ORANGE, font=("Segoe UI", 11),
            border_width=1, border_color="#5a3a20",
        )
        btn.pack(side="left", padx=(0, 6))

        def _copy():
            self.clipboard_clear()
            self.clipboard_append(copy_text)
            btn.configure(text="Copied!")
            self.after(2000, lambda: btn.configure(text=f"Copy: {label}"))

        btn.configure(command=_copy)

    def _toggle_tips(self):
        """Toggle tips visibility and resize the window."""
        self._tips_visible = not self._tips_visible
        if self._tips_frame:
            self._build_tips(self._tips_frame, self._tips_pct)
            self.update_idletasks()
            new_h = self.winfo_reqheight()
            x = self._screen_w - WINDOW_WIDTH - TASKBAR_OFFSET
            y = self._screen_h - new_h - 50
            self.geometry(f"{WINDOW_WIDTH}x{new_h}+{x}+{y}")

    @staticmethod
    def _hex(color):
        """Ensure color is a plain hex string (handle CTk tuple colors)."""
        if isinstance(color, tuple):
            return color[1] if len(color) > 1 else color[0]
        return color

    def _draw_bars(self, canvas, h, r, budget_w, usage_w, over_x, over_w):
        """Draw the rounded progress bar segments on the canvas."""
        canvas.delete("all")
        w = canvas.winfo_width()
        if w <= 1:
            return

        y0 = 1  # top offset to center vertically
        y1 = y0 + h

        # Track background
        self._rounded_rect(canvas, 0, y0, w, y1, r, "#383838")

        # Grey budget bar
        if budget_w > 0:
            bw = int(w * budget_w)
            if bw > 0:
                self._rounded_rect(canvas, 0, y0, bw, y1, r, "#555555")

        # Red exceeded bar (drawn first, behind orange)
        if over_w > 0:
            ow = int(w * (over_x + over_w))
            if ow > 0:
                self._rounded_rect(canvas, 0, y0, ow, y1, r, self._hex(RED))

        # Orange usage bar (on top, up to budget point)
        if usage_w > 0:
            # When over budget, orange only fills to budget line
            orange_w = min(usage_w, over_x) if over_w > 0 else usage_w
            uw = int(w * orange_w)
            if uw > 0:
                self._rounded_rect(canvas, 0, y0, uw, y1, r, self._hex(CLAUDE_ORANGE))

    @staticmethod
    def _rounded_rect(canvas, x1, y1, x2, y2, r, fill):
        """Draw a rounded rectangle on a canvas."""
        r = min(r, (x2 - x1) // 2, (y2 - y1) // 2)
        canvas.create_arc(x1, y1, x1 + 2*r, y1 + 2*r, start=90, extent=90, fill=fill, outline=fill)
        canvas.create_arc(x2 - 2*r, y1, x2, y1 + 2*r, start=0, extent=90, fill=fill, outline=fill)
        canvas.create_arc(x1, y2 - 2*r, x1 + 2*r, y2, start=180, extent=90, fill=fill, outline=fill)
        canvas.create_arc(x2 - 2*r, y2 - 2*r, x2, y2, start=270, extent=90, fill=fill, outline=fill)
        canvas.create_rectangle(x1 + r, y1, x2 - r, y2, fill=fill, outline=fill)
        canvas.create_rectangle(x1, y1 + r, x1 + r, y2 - r, fill=fill, outline=fill)
        canvas.create_rectangle(x2 - r, y1 + r, x2, y2 - r, fill=fill, outline=fill)

    @staticmethod
    def _calc_bar_widths(usage_pct, budget_pct):
        """Calculate relative widths for budget, usage, and over-budget bars.

        Returns (budget_w, usage_w, over_x, over_w) all in 0-1 range.
        """
        usage = max(0, min(1, usage_pct / 100))
        budget = max(0, min(1, (budget_pct / 100))) if budget_pct is not None else 0

        if budget_pct is None:
            # No budget data — just show orange usage, no grey or red
            return 0, usage, 0, 0

        if usage <= budget:
            # Under budget: orange up to usage, grey extends further
            return budget, usage, 0, 0
        else:
            # Over budget: orange fills full usage, red overlaps on top from budget to usage
            over_w = usage - budget
            return budget, usage, budget, over_w

    def _format_updated(self, data: RateLimitData) -> str:
        if data.last_updated:
            local_time = data.last_updated.astimezone()
            try:
                time_str = local_time.strftime("%#I:%M %p")
            except ValueError:
                time_str = local_time.strftime("%I:%M %p")
            stale = " (stale)" if data.is_stale else ""
            return f"Updated {time_str}{stale}"
        if not data.file_exists:
            return "No data yet - start Claude Code"
        return ""

    def _update_section(self, widgets, window, total_seconds):
        """Update a section's widgets in place — no flicker."""
        pct_label, canvas, _, _, reset_label = widgets

        pct = window.used_percentage if window else None
        pct_text = f"{pct:.0f}%" if pct is not None else "N/A"
        color = usage_color(pct)
        pct_label.configure(text=pct_text, text_color=color)

        usage_pct = pct if pct is not None else 0
        budget_pct = self._calc_budget_pct(window, total_seconds)
        budget_w, usage_w, over_x, over_w = self._calc_bar_widths(usage_pct, budget_pct)

        h = canvas._bar_height
        r = canvas._bar_radius
        self._draw_bars(canvas, h, r, budget_w, usage_w, over_x, over_w)

        # Update the configure binding too
        canvas.bind("<Configure>", lambda e, c=canvas, bw=budget_w, uw=usage_w, ox=over_x, ow=over_w:
                     self._draw_bars(c, h, r, bw, uw, ox, ow))

        reset_text = f"Resets in {window.resets_in}" if window else "No data available"
        reset_label.configure(text=reset_text)

    def _do_refresh(self):
        if self._refreshing or not self._on_refresh:
            return
        self._refreshing = True
        self._refresh_btn.configure(text="...", state="disabled")
        self._on_refresh()

    def update_data(self, data: RateLimitData):
        """Update displayed values in place — no rebuild, no flicker."""
        self._refreshing = False

        if self._fh_widgets:
            self._update_section(self._fh_widgets, data.five_hour, 5 * 3600)
        if self._sd_widgets:
            self._update_section(self._sd_widgets, data.seven_day, 7 * 86400)
        if self._sn_widgets:
            self._update_section(self._sn_widgets, data.sonnet, 7 * 86400)
        if self._updated_label:
            self._updated_label.configure(text=self._format_updated(data))
        if self._refresh_btn:
            self._refresh_btn.configure(text="Refresh", state="normal")

        # Rebuild tips and resize window if tips changed
        if self._tips_frame:
            pct = data.five_hour.used_percentage if data.five_hour else None
            self._build_tips(self._tips_frame, pct)
            self.update_idletasks()
            new_h = self.winfo_reqheight()
            x = self._screen_w - WINDOW_WIDTH - TASKBAR_OFFSET
            y = self._screen_h - new_h - 50
            self.geometry(f"{WINDOW_WIDTH}x{new_h}+{x}+{y}")