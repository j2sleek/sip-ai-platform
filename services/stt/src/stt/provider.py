"""STT provider interface and a Phase 1 placeholder implementation.

The interface establishes the contract Elixir will call across the boundary.
Real providers (e.g. faster-whisper) are added in a later phase; keeping the
interface stable means the implementation can be swapped without touching
callers (see AGENTS.md).
"""

from __future__ import annotations

import abc


class STTProvider(abc.ABC):
    """Speech-to-text provider contract.

    transcribe(audio) -> text
    """

    @abc.abstractmethod
    def transcribe(self, audio: bytes) -> str:
        """Transcribe raw PCM audio bytes to text.

        Args:
            audio: 16-bit signed PCM, mono (sample rate per the AudioChunk
                contract). Encoding details are fixed at the media boundary.

        Returns:
            The recognized transcript text.
        """
        raise NotImplementedError


class NotImplementedSTTProvider(STTProvider):
    """Placeholder provider. Raises until a real provider is wired in."""

    name = "not_implemented"

    def transcribe(self, audio: bytes) -> str:
        raise NotImplementedError("STT inference is not implemented in Phase 1")
