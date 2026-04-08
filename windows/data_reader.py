"""Reads and parses the rate-limits.json file written by the statusline script."""

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from constants import RATE_LIMITS_PATH, STALE_THRESHOLD


@dataclass
class RateLimitWindow:
    used_percentage: Optional[float]
    resets_at: Optional[datetime]
    resets_in: str  # human-readable, e.g. "2h 15m"


@dataclass
class RateLimitData:
    five_hour: Optional[RateLimitWindow]
    seven_day: Optional[RateLimitWindow]
    sonnet: Optional[RateLimitWindow]
    model: str
    last_updated: Optional[datetime]
    is_stale: bool
    file_exists: bool


def _format_time_remaining(resets_at: Optional[datetime]) -> str:
    """Format a reset time as a human-readable 'resets in' string."""
    if resets_at is None:
        return "Unknown"

    now = datetime.now(timezone.utc)
    delta = resets_at - now

    total_seconds = int(delta.total_seconds())
    if total_seconds <= 0:
        return "Resetting now"

    days = total_seconds // 86400
    hours = (total_seconds % 86400) // 3600
    minutes = (total_seconds % 3600) // 60

    parts = []
    if days > 0:
        parts.append(f"{days}d")
    if hours > 0:
        parts.append(f"{hours}h")
    if minutes > 0 or not parts:
        parts.append(f"{minutes}m")

    return " ".join(parts)


def _parse_window(data: Optional[dict]) -> Optional[RateLimitWindow]:
    """Parse a rate limit window from JSON data."""
    if not data:
        return None

    pct = data.get("used_percentage")
    resets_at_raw = data.get("resets_at")

    resets_at = None
    if resets_at_raw is not None:
        try:
            if isinstance(resets_at_raw, (int, float)):
                resets_at = datetime.fromtimestamp(resets_at_raw, tz=timezone.utc)
            elif isinstance(resets_at_raw, str):
                resets_at = datetime.fromisoformat(resets_at_raw.replace("Z", "+00:00"))
        except (ValueError, OSError):
            pass

    return RateLimitWindow(
        used_percentage=pct,
        resets_at=resets_at,
        resets_in=_format_time_remaining(resets_at),
    )


def read_rate_limits() -> RateLimitData:
    """Read the rate limits JSON file and return parsed data."""
    if not os.path.exists(RATE_LIMITS_PATH):
        return RateLimitData(
            five_hour=None,
            seven_day=None,
            sonnet=None,
            model="Unknown",
            last_updated=None,
            is_stale=True,
            file_exists=False,
        )

    try:
        with open(RATE_LIMITS_PATH, "r") as f:
            raw = json.load(f)
    except (json.JSONDecodeError, OSError):
        return RateLimitData(
            five_hour=None,
            seven_day=None,
            sonnet=None,
            model="Unknown",
            last_updated=None,
            is_stale=True,
            file_exists=True,
        )

    # Parse last_updated
    last_updated = None
    last_updated_raw = raw.get("last_updated")
    if last_updated_raw:
        try:
            last_updated = datetime.fromisoformat(
                last_updated_raw.replace("Z", "+00:00")
            )
        except ValueError:
            pass

    # Determine staleness
    is_stale = True
    if last_updated:
        age = (datetime.now(timezone.utc) - last_updated).total_seconds()
        is_stale = age > STALE_THRESHOLD

    return RateLimitData(
        five_hour=_parse_window(raw.get("five_hour")),
        seven_day=_parse_window(raw.get("seven_day")),
        sonnet=_parse_window(raw.get("sonnet")),
        model=raw.get("model", "Unknown"),
        last_updated=last_updated,
        is_stale=is_stale,
        file_exists=True,
    )