"""
UpdateService — port of ClaudeUsageMonitor/Services/UpdateService.swift

Checks the GitHub Releases API for a newer version and calls a callback
with the latest version string when one is available.
"""

from __future__ import annotations

import logging
import threading
from typing import Callable

import requests

from version import __version__

logger = logging.getLogger(__name__)

CURRENT_VERSION = __version__
REPO_API = "https://api.github.com/repos/theDanButuc/Claude-Usage-Monitor/releases/latest"
RELEASE_PAGE = "https://github.com/theDanButuc/Claude-Usage-Monitor/releases/latest"


class UpdateService:
    @property
    def release_url(self) -> str:
        return RELEASE_PAGE

    def check_for_updates(self, callback: Callable[[str | None], None]) -> None:
        """Check GitHub for a newer release.  Calls *callback* on a background
        thread with the latest version string, or None if already up to date."""
        threading.Thread(target=self._check, args=(callback,), daemon=True).start()

    def _check(self, callback: Callable[[str | None], None]) -> None:
        try:
            resp = requests.get(
                REPO_API,
                headers={"Accept": "application/vnd.github+json"},
                timeout=10,
            )
            resp.raise_for_status()
            tag = resp.json().get("tag_name", "")
            latest = tag.lstrip("v")
            if self._is_newer(latest, CURRENT_VERSION):
                callback(latest)
            else:
                callback(None)
        except Exception as exc:
            logger.warning("Update check failed: %s", exc)
            callback(None)

    @staticmethod
    def _is_newer(latest: str, current: str) -> bool:
        def _parts(v: str) -> tuple[int, ...]:
            try:
                return tuple(int(x) for x in v.split("."))
            except ValueError:
                return (0,)

        return _parts(latest) > _parts(current)
