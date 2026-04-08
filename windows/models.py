"""
UsageData model — port of ClaudeUsageMonitor/Models/UsageData.swift
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timezone


@dataclass
class TipAction:
    label: str
    copy_text: str


@dataclass
class UsageTip:
    icon: str  # emoji replacing SF Symbol names
    message: str
    actions: list[TipAction] = field(default_factory=list)


@dataclass
class UsageData:
    plan_type: str
    messages_used: int          # billing-period total (from DOM)
    messages_limit: int         # billing-period limit  (from DOM)
    session_used: int = 0       # current rate-limit window (from API interceptor)
    session_limit: int = 0      # current rate-limit window (from API interceptor)
    reset_date: datetime | None = None          # near-term reset (session window)
    weekly_reset_date: datetime | None = None   # billing period / weekly reset
    weekly_reset_text: str = ""                 # raw weekday+time string e.g. "Fri 10:00 AM"
    rate_limit_status: str = "Normal"
    last_updated: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    # Rolling window of (timestamp, session_percentage) — max 10 points
    usage_history: list[tuple[datetime, float]] = field(default_factory=list)

    # ── Computed properties ────────────────────────────────────────────────────

    @property
    def has_session_data(self) -> bool:
        return self.session_limit > 0

    @property
    def primary_used(self) -> int:
        return self.session_used if self.has_session_data else self.messages_used

    @property
    def primary_limit(self) -> int:
        return self.session_limit if self.has_session_data else self.messages_limit

    @property
    def usage_percentage(self) -> float:
        if self.primary_limit <= 0:
            return 0.0
        return min(1.0, self.primary_used / self.primary_limit)

    @property
    def session_percentage(self) -> float:
        if self.session_limit <= 0:
            return 0.0
        return min(1.0, self.session_used / self.session_limit)

    @property
    def weekly_percentage(self) -> float:
        if self.messages_limit <= 0:
            return 0.0
        return min(1.0, self.messages_used / self.messages_limit)

    @property
    def messages_remaining(self) -> int:
        return max(0, self.primary_limit - self.primary_used)

    # ── Burn rate ──────────────────────────────────────────────────────────────

    @property
    def burn_rate_per_minute(self) -> float | None:
        """Messages-per-minute consumed based on rolling history.
        Returns None if < 2 points or < 5 minutes of data (too noisy)."""
        if len(self.usage_history) < 2:
            return None
        oldest = self.usage_history[0]
        newest = self.usage_history[-1]
        minutes = (newest[0] - oldest[0]).total_seconds() / 60.0
        if minutes < 5:
            return None
        consumed = newest[1] - oldest[1]
        if consumed <= 0:
            return None
        return consumed / minutes

    @property
    def estimated_minutes_remaining(self) -> float | None:
        """Estimated minutes until session hits 100%, capped at actual reset_date."""
        rate = self.burn_rate_per_minute
        if rate is None or rate <= 0:
            return None
        remaining = 1.0 - self.session_percentage
        estimated = remaining / rate
        if self.reset_date is not None:
            now = datetime.now(timezone.utc)
            actual = (self.reset_date - now).total_seconds() / 60.0
            if actual <= 0:
                return None
            return min(estimated, actual)
        return estimated

    @property
    def burn_rate_label(self) -> str | None:
        """'~45min left' or '~2h 3m left' — None if burn rate unavailable."""
        mins = self.estimated_minutes_remaining
        if mins is None:
            return None
        if mins < 60:
            return f"~{int(mins)}min left"
        h = int(mins / 60)
        m = int(mins % 60)
        if m > 0:
            return f"~{h}h {m}m left"
        return f"~{h}h left"

    # ── Reset labels ──────────────────────────────────────────────────────────

    @property
    def time_until_reset(self) -> str:
        if self.reset_date is None:
            return "—"
        now = datetime.now(timezone.utc)
        secs = (self.reset_date - now).total_seconds()
        if secs <= 0:
            return "Soon"
        total_mins = int(secs / 60)
        h = total_mins // 60
        m = total_mins % 60
        days = h // 24
        if days > 0:
            return f"{days}d {h % 24}h"
        if h > 0:
            return f"{h}h {m}m"
        if m > 0:
            return f"{m}m"
        return "< 1m"

    @property
    def session_reset_label(self) -> str | None:
        if self.reset_date is None:
            return None
        now = datetime.now(timezone.utc)
        secs = (self.reset_date - now).total_seconds()
        if secs <= 60:
            return None
        total_mins = int(secs / 60)
        h = total_mins // 60
        m = total_mins % 60
        if h > 0:
            return f"Resets in {h} hr {m} min"
        return f"Resets in {m} min"

    @property
    def weekly_reset_label(self) -> str | None:
        if self.weekly_reset_text:
            return f"Resets {self.weekly_reset_text}"
        if self.weekly_reset_date is None:
            return None
        local_dt = self.weekly_reset_date.astimezone()
        # strftime on Windows does not support %-I (no-pad); use lstrip instead
        return "Resets " + local_dt.strftime("%a %I:%M %p").replace(" 0", " ")

    @property
    def last_updated_formatted(self) -> str:
        local_dt = self.last_updated.astimezone()
        return local_dt.strftime("%I:%M %p").lstrip("0")

    # ── Menu bar label ────────────────────────────────────────────────────────

    @property
    def menu_bar_label(self) -> str:
        session_str: str | None = None
        if self.has_session_data:
            session_str = self.burn_rate_label or f"{int(self.session_percentage * 100)}%"
        w_pct = f"{int(self.weekly_percentage * 100)}%" if self.messages_limit > 0 else None
        if session_str and w_pct:
            return f"{session_str} | {w_pct}"
        if session_str:
            return session_str
        if w_pct:
            return w_pct
        return ""

    # ── Tips ──────────────────────────────────────────────────────────────────

    @property
    def current_tips(self) -> list[UsageTip]:
        pct = self.session_percentage * 100
        tips: list[UsageTip] = []

        if pct >= 20:
            tips.append(UsageTip(
                icon="🔄",
                message="Start a new conversation for each new topic to keep context small and responses fast.",
            ))

        if pct >= 40:
            tips.append(UsageTip(
                icon="⚡",
                message="Compress your session to free up context. Copy the prompt and send it in your current conversation:",
                actions=[
                    TipAction(
                        label="claude.ai",
                        copy_text="Please summarize our conversation so far in under 200 words so we can continue efficiently.",
                    ),
                    TipAction(label="/compact", copy_text="/compact"),
                ],
            ))

        if pct >= 60:
            tips.append(UsageTip(
                icon="📄",
                message="Avoid re-uploading large files. Reference content already shared earlier in the conversation.",
            ))

        if pct >= 75:
            tips.append(UsageTip(
                icon="✅",
                message="Wrap up long threads. Save important outputs before your session resets.",
            ))

        if pct >= 85:
            tips.append(UsageTip(
                icon="⚠️",
                message="Best for short tasks now: quick questions, code review, short edits. Avoid starting new long projects.",
            ))

        if pct >= 95:
            reset_label = self.session_reset_label or "Session resets soon"
            tips.append(UsageTip(
                icon="🚫",
                message=f"Almost out. Save your work now. {reset_label}.",
            ))

        return tips

    # ── Stale ─────────────────────────────────────────────────────────────────

    @property
    def is_stale(self) -> bool:
        now = datetime.now(timezone.utc)
        return (now - self.last_updated).total_seconds() > 600
