"""LLM provider interface and implementations.

The interface (`generate(messages) -> response`) is the stable contract the
platform calls across the boundary; implementations are swappable without
touching callers (AGENTS.md rule 5).

Providers:

  * ``MockLLMProvider``   — dependency-free, deterministic (default). Echoes or
    returns a configured canned reply; used by tests and the demo harness.
  * ``OllamaLLMProvider`` — talks to a local Ollama daemon over HTTP.
  * ``OpenRouterLLMProvider`` — free-tier compatible OpenRouter API.
  * ``GroqLLMProvider`` — Groq API (free tier available).
  * ``GoogleGeminiLLMProvider`` — Google AI Studio (Gemini API) free tier.
"""

from __future__ import annotations

import abc
import json
import os
import urllib.error
import urllib.request
from typing import Any

from .errors import ProviderError
from .httpclient import urlopen as _urlopen

DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
DEFAULT_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
# Free, currently-hosted Groq models. gpt-oss-20b is the low-latency default for
# voice; override with LLM_MODEL (e.g. openai/gpt-oss-120b for higher quality).
DEFAULT_GROQ_MODEL = "openai/gpt-oss-20b"

# Cloudflare (fronting Groq/OpenRouter) rejects the default python-urllib
# User-Agent with HTTP 403 / error 1010, so `_urlopen` (from .httpclient) always
# sends an explicit UA. It also pools keep-alive connections to cut per-request
# DNS + TCP + TLS setup on the cloud path.
DEFAULT_GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models"


class LLMProvider(abc.ABC):
    """LLM provider contract.

    generate(messages) -> response
    """

    name = "abstract"
    model = ""

    @abc.abstractmethod
    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        """Generate an assistant response from a message history.

        Args:
            messages: chat messages shaped like the AgentMessage contract
                (`{"role": ..., "content": ...}`).

        Returns:
            A response dict shaped like the AgentMessage contract.
        """
        raise NotImplementedError


class NotImplementedLLMProvider(LLMProvider):
    """Placeholder provider. Raises until a real provider is wired in."""

    name = "not_implemented"

    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        raise NotImplementedError("LLM inference is not implemented in Phase 1")


def _last_user_content(messages: list[dict[str, Any]]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return str(message.get("content", ""))
    return ""


class MockLLMProvider(LLMProvider):
    """Deterministic, dependency-free provider.

    Returns ``LLM_MOCK_REPLY`` when set, otherwise echoes the last user message.
    This keeps the platform conversational end-to-end without any model.
    """

    name = "mock"
    model = os.environ.get("LLM_MODEL", "mock-1")

    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        configured = os.environ.get("LLM_MOCK_REPLY")
        content = configured if configured is not None else f"You said: {_last_user_content(messages)}"
        return {"role": "assistant", "content": content}


class OllamaLLMProvider(LLMProvider):
    """Local Ollama adapter (`POST {OLLAMA_URL}/api/chat`)."""

    name = "ollama"

    def __init__(self, url: str, model: str, timeout_s: float = 30.0) -> None:
        self._url = url.rstrip("/") + "/api/chat"
        self.model = model
        self._timeout = timeout_s

    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        payload = json.dumps(
            {"model": self.model, "messages": messages, "stream": False}
        ).encode("utf-8")
        request = urllib.request.Request(
            self._url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with _urlopen(request, self._timeout) as resp:
                body = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise ProviderError(
                f"ollama returned HTTP {exc.code}", code="provider_http_error", status=502
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(
                f"ollama unreachable: {exc}", code="provider_unreachable"
            ) from exc
        except json.JSONDecodeError as exc:
            raise ProviderError("ollama returned invalid JSON", code="provider_bad_payload") from exc

        message = body.get("message") or {}
        content = message.get("content")
        if not isinstance(content, str):
            raise ProviderError("ollama response missing message.content", code="provider_bad_payload")

        return {"role": "assistant", "content": content}


class OpenRouterLLMProvider(LLMProvider):
    """OpenRouter API (OpenAI-compatible) - supports many free models."""
    name = "openrouter"

    def __init__(self, api_key: str, model: str, timeout_s: float = 30.0, url: str = DEFAULT_OPENROUTER_URL):
        self._url = url
        self.model = model
        self._api_key = api_key
        self._timeout = timeout_s

    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        payload = json.dumps(
            {"model": self.model, "messages": messages, "stream": False}
        ).encode("utf-8")
        request = urllib.request.Request(
            self._url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._api_key}",
                "HTTP-Referer": os.environ.get("OPENROUTER_SITE_URL", "http://localhost"),
                "X-Title": os.environ.get("OPENROUTER_APP_NAME", "sip-ai-platform"),
            },
            method="POST",
        )

        try:
            with _urlopen(request, self._timeout) as resp:
                body = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise ProviderError(
                f"openrouter returned HTTP {exc.code}", code="provider_http_error", status=502
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(
                f"openrouter unreachable: {exc}", code="provider_unreachable"
            ) from exc
        except json.JSONDecodeError as exc:
            raise ProviderError("openrouter returned invalid JSON", code="provider_bad_payload") from exc

        choices = body.get("choices") or []
        if not choices:
            raise ProviderError("openrouter response missing choices", code="provider_bad_payload")
        message = choices[0].get("message") or {}
        content = message.get("content")
        if not isinstance(content, str):
            raise ProviderError("openrouter response missing message.content", code="provider_bad_payload")
        return {"role": "assistant", "content": content}


class GroqLLMProvider(LLMProvider):
    """Groq API (OpenAI-compatible) - very fast, good free tier."""
    name = "groq"

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_GROQ_MODEL,
        timeout_s: float = 30.0,
        url: str = DEFAULT_GROQ_URL,
        max_tokens: int | None = None,
        reasoning_effort: str | None = None,
    ):
        self._url = url
        self.model = model
        self._api_key = api_key
        self._timeout = timeout_s
        self._max_tokens = max_tokens
        self._reasoning_effort = reasoning_effort

    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        body: dict[str, Any] = {"model": self.model, "messages": messages, "stream": False}
        # gpt-oss and other reasoning models spend completion budget on internal
        # reasoning tokens; without an explicit cap the visible content can be
        # truncated to an empty string.
        if self._max_tokens:
            payload_max_tokens = self._max_tokens
            body["max_tokens"] = payload_max_tokens
        if self._reasoning_effort:
            body["reasoning_effort"] = self._reasoning_effort
        payload = json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            self._url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._api_key}",
            },
            method="POST",
        )

        try:
            with _urlopen(request, self._timeout) as resp:
                body = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise ProviderError(
                f"groq returned HTTP {exc.code}", code="provider_http_error", status=502
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(
                f"groq unreachable: {exc}", code="provider_unreachable"
            ) from exc
        except json.JSONDecodeError as exc:
            raise ProviderError("groq returned invalid JSON", code="provider_bad_payload") from exc

        choices = body.get("choices") or []
        if not choices:
            raise ProviderError("groq response missing choices", code="provider_bad_payload")
        message = choices[0].get("message") or {}
        content = message.get("content")
        if not isinstance(content, str):
            raise ProviderError("groq response missing message.content", code="provider_bad_payload")
        return {"role": "assistant", "content": content}


class GoogleGeminiLLMProvider(LLMProvider):
    """Google Gemini API (AI Studio)."""
    name = "gemini"

    def __init__(self, api_key: str, model: str, timeout_s: float = 30.0):
        self.model = model
        self._api_key = api_key
        self._timeout = timeout_s
        self._url = f"{DEFAULT_GEMINI_URL}/{model}:generateContent?key={api_key}"

    def generate(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        # Convert OpenAI-style messages to Gemini format
        contents = []
        for m in messages:
            role = m.get("role", "user")
            gemini_role = "model" if role == "assistant" else "user"
            contents.append({"role": gemini_role, "parts": [{"text": m.get("content", "")}]})
        payload = json.dumps({"contents": contents}).encode("utf-8")
        request = urllib.request.Request(
            self._url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with _urlopen(request, self._timeout) as resp:
                body = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise ProviderError(
                f"gemini returned HTTP {exc.code}", code="provider_http_error", status=502
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(
                f"gemini unreachable: {exc}", code="provider_unreachable"
            ) from exc
        except json.JSONDecodeError as exc:
            raise ProviderError("gemini returned invalid JSON", code="provider_bad_payload") from exc

        candidates = body.get("candidates") or []
        if not candidates:
            raise ProviderError("gemini response missing candidates", code="provider_bad_payload")
        content = candidates[0].get("content") or {}
        parts = content.get("parts") or []
        if not parts:
            raise ProviderError("gemini response missing parts", code="provider_bad_payload")
        text = parts[0].get("text", "")
        return {"role": "assistant", "content": text}


def get_provider(name: str | None = None) -> LLMProvider:
    """Builds the configured provider (``LLM_PROVIDER``, default ``mock``)."""
    name = (name or os.environ.get("LLM_PROVIDER", "mock")).lower()

    if name == "mock":
        return MockLLMProvider()
    if name == "ollama":
        url = os.environ.get("OLLAMA_URL", DEFAULT_OLLAMA_URL)
        model = os.environ.get("LLM_MODEL", "llama3.2")
        timeout = float(os.environ.get("LLM_REQUEST_TIMEOUT_S", "30"))
        return OllamaLLMProvider(url, model, timeout_s=timeout)
    if name == "openrouter":
        api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("OPENROUTER_API_KEY required for openrouter provider")
        model = os.environ.get("LLM_MODEL", "mistralai/mistral-7b-instruct:free")
        timeout = float(os.environ.get("LLM_REQUEST_TIMEOUT_S", "30"))
        return OpenRouterLLMProvider(api_key, model, timeout_s=timeout)
    if name == "groq":
        api_key = os.environ.get("GROQ_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("GROQ_API_KEY required for groq provider")
        model = os.environ.get("LLM_MODEL", DEFAULT_GROQ_MODEL)
        timeout = float(os.environ.get("LLM_REQUEST_TIMEOUT_S", "30"))
        max_tokens = int(os.environ.get("LLM_MAX_TOKENS", "1024"))
        reasoning_effort = os.environ.get("LLM_REASONING_EFFORT", "").strip() or None
        return GroqLLMProvider(
            api_key, model, timeout_s=timeout, max_tokens=max_tokens,
            reasoning_effort=reasoning_effort,
        )
    if name in ("gemini", "google", "googleai"):
        api_key = os.environ.get("GEMINI_API_KEY", "").strip() or os.environ.get("GOOGLE_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("GEMINI_API_KEY (or GOOGLE_API_KEY) required for gemini provider")
        model = os.environ.get("LLM_MODEL", "gemini-2.5-flash-lite")
        timeout = float(os.environ.get("LLM_REQUEST_TIMEOUT_S", "30"))
        return GoogleGeminiLLMProvider(api_key, model, timeout_s=timeout)

    raise ProviderError(f"unknown LLM_PROVIDER: {name}", code="unknown_provider")
