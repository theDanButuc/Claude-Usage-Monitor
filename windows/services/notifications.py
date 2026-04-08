"""
NotificationService — port of ClaudeUsageMonitor/Services/NotificationService.swift

Sends Windows toast notifications via winotify.  Falls back to a simple
print/logging statement if winotify is not available (e.g. running on
non-Windows for development).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from models import UsageData

logger = logging.getLogger(__name__)

try:
    from winotify import Notification, audio

    _WINOTIFY_AVAILABLE = True
except ImportError:
    _WINOTIFY_AVAILABLE = False
    logger.warning("winotify not installed — notifications will be logged only.")


class NotificationService:
    def __init__(self, app_id: str = "Claude Usage Monitor") -> None:
        self._app_id = app_id
        self._notified_thresholds: set[int] = set()
        self._last_known_reset_date: datetime | None = None

    # ── Main entry point ───────────────────────────────────────────────────────

    def check_and_notify(self, data: UsageData) -> None:
        self._check_usage_thresholds(data)
        self._check_session_reset(data)

    # ── Usage threshold alerts ─────────────────────────────────────────────────

    def _check_usage_thresholds(self, data: UsageData) -> None:
        pct = data.session_percentage if data.has_session_data else data.usage_percentage

        config = [
            (75,  "Halfway through your session",
                  "Consider wrapping up long threads. Start fresh conversations for new topics."),
            (80,  "Session at 80%",
                  "Avoid new long projects or file uploads. Best for: quick questions, short edits, code review."),
            (90,  "Session at 90% — act fast",
                  "~10% left. Finish your current task and save important outputs before the limit hits."),
            (95,  "Almost out",
                  f"Save your work now. {data.session_reset_label or 'Session resets soon'}."),
            (100, "Claude Limit Reached",
                  f"You've used your full quota. {data.session_reset_label or 'Resets soon'}."),
        ]

        for threshold, title, body in config:
            fraction = threshold / 100.0
            if pct >= fraction:
                if threshold not in self._notified_thresholds:
                    self._notified_thresholds.add(threshold)
                    self._send(title, body, f"claude-tip-{threshold}")
            else:
                self._notified_thresholds.discard(threshold)

    # ── Session reset detection ────────────────────────────────────────────────

    def _check_session_reset(self, data: UsageData) -> None:
        new_reset = data.reset_date
        if new_reset is None:
            return

        if self._last_known_reset_date is not None:
            delta = (new_reset - self._last_known_reset_date).total_seconds()
            if delta > 3600:
                self._notified_thresholds.clear()
                now_ts = int(datetime.now(timezone.utc).timestamp())
                self._send(
                    "Claude Session Reset",
                    "Your usage window has reset. You have a full quota available.",
                    f"claude-reset-{now_ts}",
                )

        self._last_known_reset_date = new_reset

    # ── Low-level send ─────────────────────────────────────────────────────────

    def _send(self, title: str, body: str, notification_id: str) -> None:
        logger.info("Notification [%s]: %s — %s", notification_id, title, body)
        if not _WINOTIFY_AVAILABLE:
            return
        try:
            toast = Notification(
                app_id=self._app_id,
                title=title,
                msg=body,
                duration="short",
            )
            toast.set_audio(audio.Default, loop=False)
            toast.show()
        except Exception as exc:
            logger.warning("Failed to send notification: %s", exc)
