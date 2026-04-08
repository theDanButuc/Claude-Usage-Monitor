"""Constants for the Claude Code usage tray app."""

import os

# Paths
RATE_LIMITS_PATH = os.path.join(os.path.expanduser("~"), ".claude", "rate-limits.json")

# Timing
POLL_INTERVAL_MS = 5000  # 5 seconds

# Window
WINDOW_WIDTH = 340
WINDOW_HEIGHT = 470
TASKBAR_OFFSET = 10  # pixels from screen edge

# Stale data threshold (seconds)
STALE_THRESHOLD = 600  # 10 minutes

# Colors — neutral dark theme
BG_COLOR = "#1e1e1e"
CARD_BG = "#2a2a2a"
TEXT_PRIMARY = "#d4d4d4"
TEXT_SECONDARY = "#808080"
TEXT_TITLE = "#f0f0f0"
CLAUDE_ORANGE = "#d97757"
GREEN = "#73c991"
YELLOW = "#e5c07b"
RED = "#e06c75"
ACCENT = "#555555"
BORDER_COLOR = "#3a3a3a"

# Icon
ICON_SIZE = 64


def usage_color(percentage):
    """Return color based on usage percentage."""
    if percentage is None:
        return TEXT_SECONDARY
    if percentage < 60:
        return GREEN
    if percentage < 80:
        return YELLOW
    return RED