"""TTS provider interface and a Phase 1 placeholder implementation.

Real providers (e.g. Piper) are added later; the stable interface lets the
implementation be swapped without touching callers (see AGENTS.md).
"""

from __future__ import annotations

import abc


class TTSProvider(abc.ABC):
    """Text-to-speech provider contract.

    synthesize(text) -> audio
    """

    @abc.abstractmethod
    def synthesize(self, text: str) -> bytes:
        """Synthesize speech audio from text.

        Args:
            text: the text to speak.

        Returns:
            Raw PCM audio bytes (format fixed at the media boundary, per the
            AudioChunk contract).
        """
        raise NotImplementedError


class NotImplementedTTSProvider(TTSProvider):
    """Placeholder provider. Raises until a real provider is wired in."""

    name = "not_implemented"

    def synthesize(self, text: str) -> bytes:
        raise NotImplementedError("TTS synthesis is not implemented in Phase 1")
