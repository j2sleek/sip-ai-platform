"""STT provider interface and implementations.

The interface (`transcribe(audio) -> text`) is the stable contract the Elixir
core calls across the boundary; implementations are swappable without touching
callers (AGENTS.md rule 5).

Providers:

  * ``MockSTTProvider``     — dependency-free, deterministic (default). Used by
    tests and by the demo/integration harness; never touches a model.
  * ``CommandSTTProvider``  — runs an external STT binary (e.g. whisper.cpp)
    with the PCM audio on stdin and the transcript on stdout. Configured via
    ``STT_COMMAND``.
  * ``GroqSTTProvider``     — Groq STT (OpenAI-compatible /v1/audio/transcriptions)
  * ``OpenRouterSTTProvider`` — OpenRouter STT (OpenAI-compatible /v1/audio/transcriptions)
  * ``GeminiSTTProvider``    — Google Gemini via Generative Language API

Real providers must respect a timeout and raise ``ProviderError`` on failure
(never leak a raw exception across the boundary).
"""

from __future__ import annotations

import abc
import base64
import json
import os
import shlex
import struct
import subprocess
import urllib.error
import urllib.request

from .errors import ProviderError
from .httpclient import urlopen as _urlopen

DEFAULT_MOCK_TEXT = "reference transcript for testing"

# Default endpoints
DEFAULT_GROQ_STT_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
DEFAULT_OPENROUTER_STT_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
DEFAULT_GEMINI_STT_URL_TEMPLATE = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

# Default models
DEFAULT_GROQ_STT_MODEL = "whisper-large-v3-turbo"
DEFAULT_OPENROUTER_STT_MODEL = "openai/whisper-large-v3-turbo"
DEFAULT_GEMINI_STT_MODEL = "gemini-2.5-flash"

# Assume 16-bit PCM mono at 16kHz as a common default for telephony-like audio;
# this matches how the server estimates duration when sample_rate is provided,
# but the helper is minimal. For our use cases, 16kHz is reasonable.
DEFAULT_PCM_SAMPLE_RATE = 16000

# Cloudflare (fronting Groq/OpenRouter) rejects the default python-urllib
# User-Agent with HTTP 403 / error 1010, so `_urlopen` (from .httpclient) always
# sends an explicit UA. It also pools keep-alive connections to cut per-request
# DNS + TCP + TLS setup on the cloud path.


def _make_wav_header(pcm_bytes: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE, channels: int = 1, bits_per_sample: int = 16) -> bytes:
    """Create a minimal WAV header for 16-bit PCM audio."""
    byte_rate = sample_rate * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8
    data_size = len(pcm_bytes)
    riff_size = 36 + data_size

    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        riff_size,
        b"WAVE",
        b"fmt ",
        16,  # PCM
        1,  # AudioFormat (PCM)
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
        b"data",
        data_size,
    )


class STTProvider(abc.ABC):
    """Speech-to-text provider contract."""

    name = "abstract"

    @abc.abstractmethod
    def transcribe(self, audio: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE) -> str:
        """Transcribe raw 16-bit little-endian mono PCM at ``sample_rate`` Hz."""
        raise NotImplementedError


class NotImplementedSTTProvider(STTProvider):
    """Placeholder provider. Raises until a real provider is wired in."""

    name = "not_implemented"

    def transcribe(self, audio: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE) -> str:
        raise NotImplementedError("STT inference is not implemented in Phase 1")


class MockSTTProvider(STTProvider):
    """Deterministic, dependency-free provider."""

    name = "mock"

    def __init__(self, text: str | None = None) -> None:
        self._text = text if text is not None else os.environ.get("STT_MOCK_TEXT", DEFAULT_MOCK_TEXT)

    def transcribe(self, audio: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE) -> str:
        if not audio:
            return ""
        return self._text


class CommandSTTProvider(STTProvider):
    """Runs an external STT command with PCM on stdin, text on stdout."""

    name = "command"

    def __init__(self, command: str, timeout_s: float = 30.0) -> None:
        self._argv = shlex.split(command)
        self._timeout = timeout_s

    def transcribe(self, audio: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE) -> str:
        if not audio:
            return ""
        try:
            completed = subprocess.run(
                self._argv,
                input=audio,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self._timeout,
                check=False,
            )
        except FileNotFoundError as exc:
            raise ProviderError(f"stt command not found: {self._argv[0]}") from exc
        except subprocess.TimeoutExpired as exc:
            raise ProviderError(
                f"stt command timed out after {self._timeout}s", code="provider_timeout"
            ) from exc

        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", "replace").strip()[:500]
            raise ProviderError(f"stt command failed ({completed.returncode}): {detail}")

        return completed.stdout.decode("utf-8", "replace").strip()


class GroqSTTProvider(STTProvider):
    """Groq STT API (OpenAI-compatible) - /v1/audio/transcriptions."""

    name = "groq"

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_GROQ_STT_MODEL,
        timeout_s: float = 30.0,
        url: str = DEFAULT_GROQ_STT_URL,
    ) -> None:
        self._url = url
        self._api_key = api_key
        self._model = model
        self._timeout = timeout_s

    def transcribe(self, audio: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE) -> str:
        if not audio:
            return ""

        boundary = "----WebKitFormBoundarySTT"
        body_parts = []
        body_parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{self._model}\r\n".encode(
                "utf-8"
            )
        )
        # Send as WAV with minimal header to be compatible with some APIs
        wav_audio = _make_wav_header(audio, sample_rate) + audio
        body_parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode(
                "utf-8"
            )
        )
        body_parts.append(wav_audio)
        body_parts.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
        payload = b"".join(body_parts)

        request = urllib.request.Request(
            self._url,
            data=payload,
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
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
            raise ProviderError(f"groq unreachable: {exc}", code="provider_unreachable") from exc
        except json.JSONDecodeError as exc:
            raise ProviderError("groq returned invalid JSON", code="provider_bad_payload") from exc

        if isinstance(body, dict):
            text = body.get("text") or body.get("transcription")
            if isinstance(text, str):
                return text.strip()
            raise ProviderError("groq response missing text", code="provider_bad_payload")

        raise ProviderError("groq response missing text", code="provider_bad_payload")


class OpenRouterSTTProvider(STTProvider):
    """OpenRouter STT API (OpenAI-compatible) - /api/v1/audio/transcriptions."""

    name = "openrouter"

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_OPENROUTER_STT_MODEL,
        timeout_s: float = 30.0,
        url: str = DEFAULT_OPENROUTER_STT_URL,
    ) -> None:
        self._url = url
        self._api_key = api_key
        self._model = model
        self._timeout = timeout_s

    def transcribe(self, audio: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE) -> str:
        if not audio:
            return ""

        boundary = "----WebKitFormBoundarySTT"
        body_parts = []
        body_parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{self._model}\r\n".encode(
                "utf-8"
            )
        )
        # Send as WAV with minimal header to be compatible with some APIs
        wav_audio = _make_wav_header(audio, sample_rate) + audio
        body_parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode(
                "utf-8"
            )
        )
        body_parts.append(wav_audio)
        body_parts.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
        payload = b"".join(body_parts)

        request = urllib.request.Request(
            self._url,
            data=payload,
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
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
            raise ProviderError(f"openrouter unreachable: {exc}", code="provider_unreachable") from exc
        except json.JSONDecodeError as exc:
            raise ProviderError("openrouter returned invalid JSON", code="provider_bad_payload") from exc

        if isinstance(body, dict):
            text = body.get("text") or body.get("transcription")
            if isinstance(text, str):
                return text.strip()
            raise ProviderError("openrouter response missing text", code="provider_bad_payload")

        raise ProviderError("openrouter response missing text", code="provider_bad_payload")


class GeminiSTTProvider(STTProvider):
    """Google Gemini via Generative Language API."""

    name = "gemini"

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_GEMINI_STT_MODEL,
        timeout_s: float = 30.0,
        url_template: str = DEFAULT_GEMINI_STT_URL_TEMPLATE,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._timeout = timeout_s
        self._url_template = url_template

    def transcribe(self, audio: bytes, sample_rate: int = DEFAULT_PCM_SAMPLE_RATE) -> str:
        if not audio:
            return ""

        url = self._url_template.format(model=self._model)
        if self._api_key:
            url = f"{url}?key={self._api_key}"

        payload = json.dumps(
            {
                "contents": [
                    {
                        "parts": [
                            {
                                "inlineData": {
                                    "mimeType": "audio/pcm",
                                    "data": base64.b64encode(audio).decode("utf-8"),
                                }
                            },
                            {"text": "Transcribe this audio to text."},
                        ]
                    }
                ]
            }
        ).encode("utf-8")

        request = urllib.request.Request(
            url,
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
            raise ProviderError(f"gemini unreachable: {exc}", code="provider_unreachable") from exc
        except json.JSONDecodeError as exc:
            raise ProviderError("gemini returned invalid JSON", code="provider_bad_payload") from exc

        if isinstance(body, dict):
            candidates = body.get("candidates") or []
            if candidates:
                content = candidates[0].get("content") or {}
                parts = content.get("parts") or []
                text_parts = []
                for part in parts:
                    if isinstance(part, dict) and isinstance(part.get("text"), str):
                        text_parts.append(part["text"])
                if text_parts:
                    return " ".join(text_parts).strip()
            raise ProviderError("gemini response missing text", code="provider_bad_payload")

        raise ProviderError("gemini response missing text", code="provider_bad_payload")


def get_provider(name: str | None = None) -> STTProvider:
    """Builds the configured provider (``STT_PROVIDER``, default ``mock``)."""
    name = (name or os.environ.get("STT_PROVIDER", "mock")).lower()

    if name == "mock":
        return MockSTTProvider()
    if name == "command":
        command = os.environ.get("STT_COMMAND", "").strip()
        if not command:
            raise ProviderError("STT_PROVIDER=command requires STT_COMMAND")
        timeout = float(os.environ.get("STT_COMMAND_TIMEOUT_S", "30"))
        return CommandSTTProvider(command, timeout_s=timeout)
    if name == "groq":
        api_key = os.environ.get("GROQ_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("STT_PROVIDER=groq requires GROQ_API_KEY")
        model = os.environ.get("STT_GROQ_MODEL", DEFAULT_GROQ_STT_MODEL).strip() or DEFAULT_GROQ_STT_MODEL
        url = os.environ.get("STT_GROQ_URL", DEFAULT_GROQ_STT_URL).strip() or DEFAULT_GROQ_STT_URL
        timeout = float(os.environ.get("STT_TIMEOUT_S", os.environ.get("STT_GROQ_TIMEOUT_S", "30")))
        return GroqSTTProvider(api_key=api_key, model=model, timeout_s=timeout, url=url)
    if name == "openrouter":
        api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("STT_PROVIDER=openrouter requires OPENROUTER_API_KEY")
        model = os.environ.get("STT_OPENROUTER_MODEL", DEFAULT_OPENROUTER_STT_MODEL).strip() or DEFAULT_OPENROUTER_STT_MODEL
        url = os.environ.get("STT_OPENROUTER_URL", DEFAULT_OPENROUTER_STT_URL).strip() or DEFAULT_OPENROUTER_STT_URL
        timeout = float(os.environ.get("STT_TIMEOUT_S", os.environ.get("STT_OPENROUTER_TIMEOUT_S", "30")))
        return OpenRouterSTTProvider(api_key=api_key, model=model, timeout_s=timeout, url=url)
    if name == "gemini":
        api_key = os.environ.get("GEMINI_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("STT_PROVIDER=gemini requires GEMINI_API_KEY")
        model = os.environ.get("STT_GEMINI_MODEL", DEFAULT_GEMINI_STT_MODEL).strip() or DEFAULT_GEMINI_STT_MODEL
        url_template = os.environ.get("STT_GEMINI_URL_TEMPLATE", DEFAULT_GEMINI_STT_URL_TEMPLATE).strip() or DEFAULT_GEMINI_STT_URL_TEMPLATE
        timeout = float(os.environ.get("STT_TIMEOUT_S", os.environ.get("STT_GEMINI_TIMEOUT_S", "30")))
        return GeminiSTTProvider(api_key=api_key, model=model, timeout_s=timeout, url_template=url_template)

    raise ProviderError(f"unknown STT_PROVIDER: {name}", code="unknown_provider")
