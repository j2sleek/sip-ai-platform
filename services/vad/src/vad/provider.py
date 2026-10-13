"""VAD provider interface and implementations.

The interface (`analyze(audio, sample_rate, threshold) -> analysis`) is the
stable contract callers use; implementations are swappable (AGENTS.md rule 5).

Providers:

  * ``EnergyVADProvider`` — dependency-free RMS/energy detector (default). Fast,
    deterministic, and model-free; suitable for telephony-rate 16-bit PCM.
"""

from __future__ import annotations

import abc
import array
import math
import sys

DEFAULT_SAMPLE_RATE = 8000
DEFAULT_THRESHOLD = 300.0
SILENCE_FLOOR_DB = -100.0


def decode_s16(data: bytes, encoding: str = "pcm_s16be") -> "array.array":
    """Decodes 16-bit PCM bytes into host-order samples."""
    if len(data) % 2:
        data = data[:-1]
    buf = array.array("h")
    buf.frombytes(data)
    # Normalise to host order so arithmetic is endianness-independent.
    if encoding.endswith("be"):
        if sys.byteorder == "little":
            buf.byteswap()
    elif encoding.endswith("le"):
        if sys.byteorder == "big":
            buf.byteswap()
    return buf


class VADProvider(abc.ABC):
    """Voice-activity provider contract."""

    name = "abstract"

    @abc.abstractmethod
    def analyze(self, audio: bytes, sample_rate: int, threshold: float, encoding: str) -> dict:
        """Analyse a PCM buffer and report speech presence and energy."""
        raise NotImplementedError


class EnergyVADProvider(VADProvider):
    """Energy (RMS) based detector for 16-bit PCM."""

    name = "energy"

    def analyze(
        self,
        audio: bytes,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        threshold: float = DEFAULT_THRESHOLD,
        encoding: str = "pcm_s16be",
    ) -> dict:
        samples = decode_s16(audio, encoding)
        count = len(samples)

        if count == 0:
            return {
                "speech": False,
                "rms": 0.0,
                "energy_db": SILENCE_FLOOR_DB,
                "samples": 0,
                "duration_ms": 0.0,
                "threshold": threshold,
            }

        sum_squares = 0
        for value in samples:
            sum_squares += value * value
        rms = math.sqrt(sum_squares / count)
        energy_db = 20.0 * math.log10(rms / 32768.0) if rms > 0 else SILENCE_FLOOR_DB

        return {
            "speech": rms >= threshold,
            "rms": round(rms, 3),
            "energy_db": round(max(energy_db, SILENCE_FLOOR_DB), 3),
            "samples": count,
            "duration_ms": round(count / sample_rate * 1000, 3),
            "threshold": threshold,
        }


def get_provider(name: str | None = None) -> VADProvider:
    """Builds the configured provider (``VAD_PROVIDER``, default ``energy``)."""
    import os

    name = (name or os.environ.get("VAD_PROVIDER", "energy")).lower()
    if name == "energy":
        return EnergyVADProvider()
    raise ValueError(f"unknown VAD_PROVIDER: {name}")
