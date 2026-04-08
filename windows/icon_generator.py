"""Generates dynamic tray icons showing usage percentage as a colored gauge."""

import math

from PIL import Image, ImageDraw, ImageFont

from constants import (
    BG_COLOR,
    GREEN,
    ICON_SIZE,
    RED,
    TEXT_SECONDARY,
    YELLOW,
    usage_color,
)


def _hex_to_rgb(hex_color: str) -> tuple:
    """Convert hex color to RGB tuple."""
    h = hex_color.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def create_icon(percentage=None) -> Image.Image:
    """Create a 64x64 tray icon with a circular usage gauge.

    Args:
        percentage: Usage percentage (0-100), or None for no data.

    Returns:
        PIL Image suitable for pystray.
    """
    size = ICON_SIZE
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    center = size // 2
    radius = size // 2 - 2
    bg_ring_color = _hex_to_rgb(BG_COLOR) + (255,)

    # Draw background circle
    draw.ellipse(
        [center - radius, center - radius, center + radius, center + radius],
        fill=(30, 30, 30, 255),
        outline=(58, 58, 58, 255),
        width=1,
    )

    if percentage is not None:
        # Draw arc for usage
        color = _hex_to_rgb(usage_color(percentage))
        arc_color = color + (255,)

        # Background arc (dark ring)
        ring_width = 6
        ring_bbox = [
            center - radius + ring_width,
            center - radius + ring_width,
            center + radius - ring_width,
            center + radius - ring_width,
        ]

        # Draw background ring
        draw.arc(ring_bbox, 0, 360, fill=(56, 56, 56, 255), width=ring_width)

        # Draw filled arc (-90 = top, clockwise)
        if percentage > 0:
            end_angle = -90 + (percentage / 100) * 360
            draw.arc(ring_bbox, -90, end_angle, fill=arc_color, width=ring_width)

    else:
        # No data — show "?" in gray
        try:
            font = ImageFont.truetype("segoeui.ttf", 24)
        except OSError:
            try:
                font = ImageFont.truetype("arial.ttf", 24)
            except OSError:
                font = ImageFont.load_default()

        text = "?"
        bbox = draw.textbbox((0, 0), text, font=font)
        text_w = bbox[2] - bbox[0]
        text_h = bbox[3] - bbox[1]
        text_x = center - text_w // 2
        text_y = center - text_h // 2 - 2
        gray = _hex_to_rgb(TEXT_SECONDARY) + (255,)
        draw.text((text_x, text_y), text, fill=gray, font=font)

    return img
