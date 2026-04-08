"""Windows toast notification service for Claude Code usage alerts."""

from datetime import datetime
from typing import Optional

from data_reader import RateLimitData

_THRESHOLDS = [
    (75, "Halfway through your session",
         "Consider wrapping up long threads. Start fresh conversations for new topics."),
    (80, "Session at 80%",
         "Avoid new long projects or file uploads. Best for: quick questions, short edits, code review."),
    (90, "Session at 90% — act fast",
         "~10% left. Finish your current task and save important outputs before the limit hits."),
    (95, "Almost out",
         "Save your work now."),
    (100, "Claude Limit Reached",
          "You've used your full quota."),
]


def _send_toast(title: str, body: str) -> None:
    try:
        from winotify import Notification
        Notification(app_id="Claude Usage Monitor", title=title, msg=body).show()
    except Exception as e:
        print(f"[notification] {e}")


class NotificationService:
    """Tracks usage thresholds and fires Windows toast notifications."""

    def __init__(self):
        self._notified: set[int] = set()
        self._last_reset_at: Optional[datetime] = None

    def check_and_notify(self, data: RateLimitData) -> None:
        self._check_thresholds(data)
        self._check_session_reset(data)

    def _check_thresholds(self, data: RateLimitData) -> None:
        window = data.five_hour
        if window is None or window.used_percentage is None:
            return

        pct = window.used_percentage

        for threshold, title, body in _THRESHOLDS:
            if pct >= threshold:
                if threshold not in self._notified:
                    self._notified.add(threshold)
                    if threshold >= 95 and window.resets_in:
                        body = f"{body} Resets in {window.resets_in}."
                    _send_toast(title, body)
            else:
                self._notified.discard(threshold)

    def _check_session_reset(self, data: RateLimitData) -> None:
        window = data.five_hour
        if window is None or window.resets_at is None:
            return

        new_reset = window.resets_at
        if self._last_reset_at is not None:
            if (new_reset - self._last_reset_at).total_seconds() > 3600:
                self._notified.clear()
                _send_toast(
                    "Claude Session Reset",
                    "Your usage window has reset. You have a full quota available.",
                )

        self._last_reset_at = new_reset
