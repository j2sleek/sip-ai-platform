"""TTS provider interface and implementations.

The interface (`synthesize(text) -> audio`) is the stable contract the platform
calls across the boundary (AGENTS.md rule 5). Audio is always returned as raw
16-bit signed PCM, big-endian, mono — the AudioSocket wire format.

Providers:

  * ``MockTTSProvider``    — dependency-free, deterministic tone (default). Used
    by tests and the demo/integration harness; never touches a model.
  * ``CommandTTSProvider`` — runs an external TTS binary (e.g. Piper) with the
    text on stdin and raw PCM on stdout. Configured via ``TTS_COMMAND``.
"""

from __future__ import annotations

import abc
import array
import io
import json
import math
import os
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
import wave

from .errors import ProviderError
from .httpclient import urlopen as _urlopen

DEFAULT_SAMPLE_RATE = 8000
DEFAULT_TONE_HZ = 220.0
DEFAULT_AMPLITUDE = 3000

# Default endpoints
DEFAULT_GROQ_TTS_URL = "https://api.groq.com/openai/v1/audio/speech"
DEFAULT_OPENROUTER_TTS_URL = "https://openrouter.ai/api/v1/audio/speech"
DEFAULT_CARTESIA_TTS_URL = "https://api.cartesia.ai/v1/tts/bytes"

# Default models
DEFAULT_GROQ_TTS_MODEL = "canopylabs/orpheus-v1-english"
DEFAULT_OPENROUTER_TTS_MODEL = "openai/tts-1"
DEFAULT_CARTESIA_TTS_MODEL = "sonic-2"

# Default voices
DEFAULT_GROQ_TTS_VOICE = "autumn"
DEFAULT_OPENROUTER_TTS_VOICE = "alloy"
DEFAULT_CARTESIA_TTS_VOICE = "aura-2-santiago"

# Groq Orpheus only returns WAV and caps input at 200 characters per request.
GROQ_TTS_MAX_INPUT_CHARS = 200
GROQ_TTS_RESPONSE_FORMAT = "wav"

# Cloudflare (fronting Groq/OpenRouter) rejects the default python-urllib
# User-Agent with HTTP 403 / error 1010, so `_urlopen` (from .httpclient) always
# sends an explicit UA. It also pools keep-alive connections to cut per-request
# DNS + TCP + TLS setup on the cloud path.


def pcm_s16be(samples: "array.array | list[int]") -> bytes:
    """Encodes 16-bit integer samples as big-endian PCM bytes."""
    buf = array.array("h", samples)
    if sys.byteorder == "little":
        buf.byteswap()
    return buf.tobytes()


def pcm_le_to_be(data: bytes) -> bytes:
    """Re-encodes little-endian 16-bit PCM as big-endian (no resampling)."""
    if len(data) % 2:
        data = data[:-1]
    buf = array.array("h")
    buf.frombytes(data)
    if sys.byteorder == "little":
        buf.byteswap()
    return buf.tobytes()


def decode_wav_mono(data: bytes) -> tuple[array.array, int]:
    """Decodes a 16-bit WAV payload into mono samples and its sample rate.

    Returns ``(samples, sample_rate)`` where ``samples`` is an ``array('h')`` in
    native byte order. Only 16-bit PCM is accepted; multi-channel audio is
    down-mixed to mono. Raises ``ProviderError`` for unsupported payloads.
    """
    try:
        with wave.open(io.BytesIO(data), "rb") as wav:
            channels = wav.getnchannels()
            width = wav.getsampwidth()
            rate = wav.getframerate()
            frames = wav.readframes(wav.getnframes())
    except (wave.Error, EOFError) as exc:
        raise ProviderError("tts returned an unreadable WAV payload", code="provider_bad_payload") from exc

    if width != 2:
        raise ProviderError(
            f"unsupported WAV sample width: {width * 8}-bit", code="provider_bad_payload"
        )

    samples = array.array("h")
    samples.frombytes(frames)
    if sys.byteorder == "big":
        samples.byteswap()

    if channels > 1:
        mono = array.array("h", [0] * (len(samples) // channels))
        for i in range(len(mono)):
            total = 0
            for c in range(channels):
                total += samples[i * channels + c]
            mono[i] = total // channels
        samples = mono

    return samples, rate


def _lowpass_kernel(cutoff_norm: float, taps: int) -> "list[float]":
    """Windowed-sinc (Blackman) low-pass kernel, ``2*taps+1`` taps.

    ``cutoff_norm`` is the cutoff in cycles/sample (0..0.5).
    """
    kernel = []
    for k in range(-taps, taps + 1):
        if k == 0:
            s = 2.0 * cutoff_norm
        else:
            s = math.sin(2.0 * math.pi * cutoff_norm * k) / (math.pi * k)
        u = k / taps
        w = 0.42 + 0.5 * math.cos(math.pi * u) + 0.08 * math.cos(2.0 * math.pi * u)
        kernel.append(s * w)
    return kernel


def _lowpass_fir(samples: array.array, cutoff_norm: float, taps: int = 16) -> array.array:
    """Anti-alias FIR low-pass. ``cutoff_norm`` is in cycles/sample (0..0.5)."""
    kernel = _lowpass_kernel(cutoff_norm, taps)
    n = len(samples)
    out = array.array("h", [0] * n)
    width = len(kernel)

    # Interior: no bounds checks.
    for i in range(taps, n - taps):
        acc = 0.0
        base = i - taps
        for k in range(width):
            acc += samples[base + k] * kernel[k]
        out[i] = _clip(acc)

    # Edges (implicit zero padding).
    for i in list(range(0, taps)) + list(range(max(taps, n - taps), n)):
        acc = 0.0
        for k in range(-taps, taps + 1):
            j = i + k
            if 0 <= j < n:
                acc += samples[j] * kernel[k + taps]
        out[i] = _clip(acc)

    return out


def _lowpass_decimate(
    samples: array.array, cutoff_norm: float, factor: int, taps: int = 16
) -> array.array:
    """Anti-aliased decimation by an integer ``factor``.

    Equivalent to a low-pass followed by taking every ``factor``-th sample, but
    only the retained outputs are convolved — ``factor``× less work.
    """
    kernel = _lowpass_kernel(cutoff_norm, taps)
    n = len(samples)
    count = n // factor
    out = array.array("h", [0] * count)

    for i in range(count):
        center = i * factor
        acc = 0.0
        j0 = center - taps
        lo = 0 if j0 < 0 else j0
        hi = n - 1 if center + taps >= n else center + taps
        k0 = lo - j0
        for j in range(lo, hi + 1):
            acc += samples[j] * kernel[k0 + (j - lo)]
        out[i] = _clip(acc)

    return out


def _clip(value: float) -> int:
    return max(-32768, min(32767, int(round(value))))


def resample_pcm(
    samples: array.array, src_rate: int, dst_rate: int, taps: int = 16
) -> array.array:
    """Resamples 16-bit PCM from ``src_rate`` to ``dst_rate``.

    Downsampling applies a windowed-sinc anti-aliasing low-pass before
    interpolation; a bare linear interpolation would fold energy above the
    destination Nyquist back into the audible band (harsh/buzzy speech on the
    8 kHz telephony path when the provider returns 24 kHz audio).
    """
    if src_rate == dst_rate or not len(samples):
        return samples

    if src_rate > dst_rate:
        # Keep the passband just under the destination Nyquist.
        cutoff = 0.5 * (dst_rate / src_rate)

        if src_rate % dst_rate == 0:
            # Exact integer decimation needs no interpolation.
            return _lowpass_decimate(samples, cutoff, src_rate // dst_rate, taps)

        samples = _lowpass_fir(samples, cutoff, taps)

    ratio = src_rate / dst_rate
    count = int(len(samples) / ratio)
    out = array.array("h", [0] * count)
    for i in range(count):
        pos = i * ratio
        idx = int(pos)
        frac = pos - idx
        a = samples[idx]
        b = samples[idx + 1] if idx + 1 < len(samples) else a
        out[i] = _clip(a + (b - a) * frac)
    return out


def chunk_text(text: str, limit: int) -> list[str]:
    """Splits ``text`` into pieces no longer than ``limit`` characters."""
    text = text.strip()
    if not text:
        return []
    if len(text) <= limit:
        return [text]

    chunks: list[str] = []
    current = ""
    for word in text.split():
        while len(word) > limit:
            if current:
                chunks.append(current)
                current = ""
            chunks.append(word[:limit])
            word = word[limit:]
        candidate = f"{current} {word}".strip()
        if len(candidate) <= limit:
            current = candidate
        else:
            if current:
                chunks.append(current)
            current = word
    if current:
        chunks.append(current)
    return chunks


class TTSProvider(abc.ABC):
    """Text-to-speech provider contract.

    synthesize(text) -> audio
    """

    name = "abstract"
    sample_rate = DEFAULT_SAMPLE_RATE

    @abc.abstractmethod
    def synthesize(self, text: str) -> bytes:
        """Synthesize speech audio from text.

        Args:
            text: the text to speak.

        Returns:
            Raw 16-bit signed PCM, big-endian, mono (AudioChunk contract).
        """
        raise NotImplementedError


class NotImplementedTTSProvider(TTSProvider):
    """Placeholder provider. Raises until a real provider is wired in."""

    name = "not_implemented"

    def synthesize(self, text: str) -> bytes:
        raise NotImplementedError("TTS synthesis is not implemented in Phase 1")


class MockTTSProvider(TTSProvider):
    """Deterministic, dependency-free provider emitting a low tone.

    The duration scales with the text length so downstream pacing and barge-in
    behave realistically. Output is 16-bit big-endian PCM at ``TTS_SAMPLE_RATE``.
    """

    name = "mock"

    def __init__(
        self,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        tone_hz: float = DEFAULT_TONE_HZ,
        amplitude: int = DEFAULT_AMPLITUDE,
    ) -> None:
        self.sample_rate = sample_rate
        self._tone_hz = tone_hz
        self._amplitude = amplitude

    def synthesize(self, text: str) -> bytes:
        duration_ms = max(200, min(30_000, 200 + 55 * len(text)))
        count = int(self.sample_rate * duration_ms / 1000)
        omega = 2.0 * math.pi * self._tone_hz / self.sample_rate
        samples = [int(self._amplitude * math.sin(omega * i)) for i in range(count)]
        return pcm_s16be(samples)


class CommandTTSProvider(TTSProvider):
    """Runs an external TTS command with text on stdin, raw PCM on stdout.

    Example (Piper, raw 16-bit output)::

        TTS_COMMAND="piper --model /models/en_US.onnx --output-raw"

    Piper emits little-endian PCM; it is re-encoded to the big-endian wire
    format. Sample-rate conversion is *not* performed here — configure a
    model/voice at ``TTS_SAMPLE_RATE`` (default 8000) for telephony use.
    """

    name = "command"

    def __init__(self, command: str, timeout_s: float = 15.0, sample_rate: int = DEFAULT_SAMPLE_RATE):
        self._argv = shlex.split(command)
        self._timeout = timeout_s
        self.sample_rate = sample_rate

    def synthesize(self, text: str) -> bytes:
        if not text:
            return b""
        try:
            completed = subprocess.run(
                self._argv,
                input=text.encode("utf-8"),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self._timeout,
                check=False,
            )
        except FileNotFoundError as exc:
            raise ProviderError(f"tts command not found: {self._argv[0]}") from exc
        except subprocess.TimeoutExpired as exc:
            raise ProviderError(
                f"tts command timed out after {self._timeout}s", code="provider_timeout"
            ) from exc

        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", "replace").strip()[:500]
            raise ProviderError(f"tts command failed ({completed.returncode}): {detail}")

        return pcm_le_to_be(completed.stdout)


class GroqTTSProvider(TTSProvider):
    """Groq TTS API (OpenAI-compatible) - /v1/audio/speech."""

    name = "groq"

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_GROQ_TTS_MODEL,
        voice: str = DEFAULT_GROQ_TTS_VOICE,
        timeout_s: float = 15.0,
        url: str = DEFAULT_GROQ_TTS_URL,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        response_format: str = GROQ_TTS_RESPONSE_FORMAT,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._timeout = timeout_s
        self._url = url
        self.sample_rate = sample_rate
        self._response_format = response_format

    def synthesize(self, text: str) -> bytes:
        if not text:
            return b""

        samples: array.array = array.array("h")
        for chunk in chunk_text(text, GROQ_TTS_MAX_INPUT_CHARS):
            audio = self._speak(chunk)
            chunk_samples, src_rate = decode_wav_mono(audio)
            samples.extend(resample_pcm(chunk_samples, src_rate, self.sample_rate))

        if not samples:
            raise ProviderError("groq returned empty audio", code="provider_bad_payload")
        return pcm_s16be(samples)

    def _speak(self, text: str) -> bytes:
        payload = json.dumps(
            {
                "model": self._model,
                "input": text,
                "voice": self._voice,
                "response_format": self._response_format,
            }
        ).encode("utf-8")

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
                audio = resp.read()
        except urllib.error.HTTPError as exc:
            raise ProviderError(
                f"groq returned HTTP {exc.code}", code="provider_http_error", status=502
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(f"groq unreachable: {exc}", code="provider_unreachable") from exc

        if not audio:
            raise ProviderError("groq returned empty audio", code="provider_bad_payload")
        return audio


class OpenRouterTTSProvider(TTSProvider):
    """OpenRouter TTS API (OpenAI-compatible) - /api/v1/audio/speech."""

    name = "openrouter"

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_OPENROUTER_TTS_MODEL,
        voice: str = DEFAULT_OPENROUTER_TTS_VOICE,
        timeout_s: float = 15.0,
        url: str = DEFAULT_OPENROUTER_TTS_URL,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        response_format: str = "pcm",
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._timeout = timeout_s
        self._url = url
        self.sample_rate = sample_rate
        self._response_format = response_format

    def synthesize(self, text: str) -> bytes:
        if not text:
            return b""

        payload = json.dumps(
            {
                "model": self._model,
                "input": text,
                "voice": self._voice,
                "response_format": self._response_format,
            }
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
                audio = resp.read()
        except urllib.error.HTTPError as exc:
            raise ProviderError(
                f"openrouter returned HTTP {exc.code}", code="provider_http_error", status=502
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(f"openrouter unreachable: {exc}", code="provider_unreachable") from exc

        if not audio:
            raise ProviderError("openrouter returned empty audio", code="provider_bad_payload")

        return pcm_le_to_be(audio)


class CartesiaTTSProvider(TTSProvider):
    """Cartesia TTS API - /v1/tts/bytes."""

    name = "cartesia"

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_CARTESIA_TTS_MODEL,
        voice: str = DEFAULT_CARTESIA_TTS_VOICE,
        timeout_s: float = 15.0,
        url: str = DEFAULT_CARTESIA_TTS_URL,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        encoding: str = "pcm_s16le",
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._timeout = timeout_s
        self._url = url
        self.sample_rate = sample_rate
        self._encoding = encoding

    def synthesize(self, text: str) -> bytes:
        if not text:
            return b""

        payload = json.dumps(
            {
                "model_id": self._model,
                "transcript": text,
                "voice": self._voice,
                "output_format": {
                    "container": "bytes",
                    "encoding": self._encoding,
                    "sample_rate": self.sample_rate,
                },
            }
        ).encode("utf-8")

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
                audio = resp.read()
        except urllib.error.HTTPError as exc:
            raise ProviderError(
                f"cartesia returned HTTP {exc.code}", code="provider_http_error", status=502
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProviderError(f"cartesia unreachable: {exc}", code="provider_unreachable") from exc

        if not audio:
            raise ProviderError("cartesia returned empty audio", code="provider_bad_payload")

        # Cartesia returns raw PCM bytes in requested encoding; normalize to big-endian
        return pcm_le_to_be(audio)


def get_provider(name: str | None = None) -> TTSProvider:
    """Builds the configured provider (``TTS_PROVIDER``, default ``mock``)."""
    name = (name or os.environ.get("TTS_PROVIDER", "mock")).lower()
    sample_rate = int(os.environ.get("TTS_SAMPLE_RATE", str(DEFAULT_SAMPLE_RATE)))

    if name == "mock":
        return MockTTSProvider(sample_rate=sample_rate)
    if name in ("command", "piper"):
        command = os.environ.get("TTS_COMMAND", "").strip()
        if not command:
            raise ProviderError("TTS_PROVIDER=command requires TTS_COMMAND")
        timeout = float(os.environ.get("TTS_COMMAND_TIMEOUT_S", "15"))
        return CommandTTSProvider(command, timeout_s=timeout, sample_rate=sample_rate)
    if name == "groq":
        api_key = os.environ.get("GROQ_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("TTS_PROVIDER=groq requires GROQ_API_KEY")
        model = os.environ.get("TTS_GROQ_MODEL", DEFAULT_GROQ_TTS_MODEL).strip() or DEFAULT_GROQ_TTS_MODEL
        voice = os.environ.get("TTS_GROQ_VOICE", DEFAULT_GROQ_TTS_VOICE).strip() or DEFAULT_GROQ_TTS_VOICE
        url = os.environ.get("TTS_GROQ_URL", DEFAULT_GROQ_TTS_URL).strip() or DEFAULT_GROQ_TTS_URL
        timeout = float(os.environ.get("TTS_TIMEOUT_S", os.environ.get("TTS_GROQ_TIMEOUT_S", "15")))
        return GroqTTSProvider(
            api_key=api_key,
            model=model,
            voice=voice,
            timeout_s=timeout,
            url=url,
            sample_rate=sample_rate,
        )
    if name == "openrouter":
        api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("TTS_PROVIDER=openrouter requires OPENROUTER_API_KEY")
        model = os.environ.get("TTS_OPENROUTER_MODEL", DEFAULT_OPENROUTER_TTS_MODEL).strip() or DEFAULT_OPENROUTER_TTS_MODEL
        voice = os.environ.get("TTS_OPENROUTER_VOICE", DEFAULT_OPENROUTER_TTS_VOICE).strip() or DEFAULT_OPENROUTER_TTS_VOICE
        url = os.environ.get("TTS_OPENROUTER_URL", DEFAULT_OPENROUTER_TTS_URL).strip() or DEFAULT_OPENROUTER_TTS_URL
        timeout = float(os.environ.get("TTS_TIMEOUT_S", os.environ.get("TTS_OPENROUTER_TIMEOUT_S", "15")))
        return OpenRouterTTSProvider(
            api_key=api_key,
            model=model,
            voice=voice,
            timeout_s=timeout,
            url=url,
            sample_rate=sample_rate,
        )
    if name == "cartesia":
        api_key = os.environ.get("CARTESIA_API_KEY", "").strip()
        if not api_key:
            raise ProviderError("TTS_PROVIDER=cartesia requires CARTESIA_API_KEY")
        model = os.environ.get("TTS_CARTESIA_MODEL", DEFAULT_CARTESIA_TTS_MODEL).strip() or DEFAULT_CARTESIA_TTS_MODEL
        voice = os.environ.get("TTS_CARTESIA_VOICE", DEFAULT_CARTESIA_TTS_VOICE).strip() or DEFAULT_CARTESIA_TTS_VOICE
        url = os.environ.get("TTS_CARTESIA_URL", DEFAULT_CARTESIA_TTS_URL).strip() or DEFAULT_CARTESIA_TTS_URL
        timeout = float(os.environ.get("TTS_TIMEOUT_S", os.environ.get("TTS_CARTESIA_TIMEOUT_S", "15")))
        return CartesiaTTSProvider(
            api_key=api_key,
            model=model,
            voice=voice,
            timeout_s=timeout,
            url=url,
            sample_rate=sample_rate,
        )

    raise ProviderError(f"unknown TTS_PROVIDER: {name}", code="unknown_provider")
