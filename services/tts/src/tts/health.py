"""Shared health payload for the tts service."""

from __future__ import annotations

from . import SERVICE_NAME, __version__


def health() -> dict:
    """Return the standard HealthResponse contract payload.

    Shape: {"status": "ok", "service": <name>, "version": <version>}
    """
    return {"status": "ok", "service": SERVICE_NAME, "version": __version__}
