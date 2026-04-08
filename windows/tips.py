"""Context-aware usage tips, mirroring the macOS app."""

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class TipAction:
    label: str
    copy_text: str


@dataclass
class UsageTip:
    icon: str
    message: str
    actions: list[TipAction] = field(default_factory=list)


def get_tips(pct: Optional[float]) -> list[UsageTip]:
    """Return tips appropriate for the given usage percentage (0–100)."""
    if pct is None:
        return []

    tips: list[UsageTip] = []

    if pct >= 20:
        tips.append(UsageTip(
            icon="↻",
            message="Start a new conversation for each new topic to keep context small and responses fast.",
        ))

    if pct >= 40:
        tips.append(UsageTip(
            icon="⚡",
            message="Compress your session to free up context. Copy a prompt and send it in your current conversation:",
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
            icon="✓",
            message="Wrap up long threads. Save important outputs before your session resets.",
        ))

    if pct >= 85:
        tips.append(UsageTip(
            icon="⚠",
            message="Best for short tasks now: quick questions, code review, short edits. Avoid starting new long projects.",
        ))

    if pct >= 95:
        tips.append(UsageTip(
            icon="✗",
            message="Almost out. Save your work now. Session resets soon.",
        ))

    return tips
