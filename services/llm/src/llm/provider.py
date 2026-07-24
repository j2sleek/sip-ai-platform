"""LLM provider interface and a Phase 1 placeholder implementation.

Real providers (e.g. an Ollama adapter) are added later; the stable interface
lets the implementation be swapped without touching callers (see AGENTS.md).
"""

from __future__ import annotations

import abc
from typing import Any


class LLMProvider(abc.ABC):
    """LLM provider contract.

    generate(messages) -> response
    """

    @abc.abstractmethod
    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        """Generate an assistant response from a message history.

        Args:
            messages: chat messages, each shaped like the AgentMessage contract
                (`{"role": ..., "content": ...}`).

        Returns:
            A response dict (shaped per the AgentMessage contract).
        """
        raise NotImplementedError


class NotImplementedLLMProvider(LLMProvider):
    """Placeholder provider. Raises until a real provider is wired in."""

    name = "not_implemented"

    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        raise NotImplementedError("LLM inference is not implemented in Phase 1")
