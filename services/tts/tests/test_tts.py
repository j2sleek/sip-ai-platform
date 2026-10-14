"""Tests for the tts service (stdlib unittest; pytest-discoverable).

Covers the provider interface, the mock tone provider, an external-command
provider, and the real HTTP server over loopback (raw PCM responses).
"""

import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import tts  # noqa: E402
from tts.errors import ProviderError  # noqa: E402
from tts.health import health  # noqa: E402
from tts.provider import (  # noqa: E402
    CommandTTSProvider,
    MockTTSProvider,
    NotImplementedTTSProvider,
    TTSProvider,
    get_provider,
    pcm_le_to_be,
    pcm_s16be,
    resample_pcm,
)
from tts.server import make_server  # noqa: E402


class TestFoundation(unittest.TestCase):
    def test_imports(self):
        self.assertEqual(tts.SERVICE_NAME, "tts")
        self.assertTrue(isinstance(tts.__version__, str))

    def test_health(self):
        payload = health()
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["service"], "tts")
        self.assertIn("version", payload)

    def test_provider_interface_exists(self):
        self.assertTrue(issubclass(NotImplementedTTSProvider, TTSProvider))

    def test_placeholder_provider_raises(self):
        provider = NotImplementedTTSProvider()
        with self.assertRaises(NotImplementedError):
            provider.synthesize("hello")


class TestPcmEncoding(unittest.TestCase):
    def test_s16be_round_trip(self):
        self.assertEqual(pcm_s16be([1, -1, 256]), b"\x00\x01\xff\xff\x01\x00")

    def test_le_to_be_swaps_bytes(self):
        self.assertEqual(pcm_le_to_be(b"\x01\x00\x00\x01"), b"\x00\x01\x01\x00")

    def test_le_to_be_drops_odd_trailing_byte(self):
        self.assertEqual(pcm_le_to_be(b"\x01\x00\xff"), b"\x00\x01")


class TestResampler(unittest.TestCase):
    @staticmethod
    def _tone(freq, rate, secs=1.0, amp=8000):
        import array
        import math

        n = int(rate * secs)
        return array.array(
            "h", [int(amp * math.sin(2 * math.pi * freq * i / rate)) for i in range(n)]
        )

    @staticmethod
    def _rms(samples):
        import math

        if not len(samples):
            return 0.0
        return math.sqrt(sum(float(x) * x for x in samples) / len(samples))

    def test_downsample_preserves_duration(self):
        src = self._tone(1000, 24000, secs=1.0)
        out = resample_pcm(src, 24000, 8000)
        self.assertEqual(len(out), 8000)

    def test_downsample_preserves_in_band_tone(self):
        src = self._tone(1000, 24000, secs=1.0)
        out = resample_pcm(src, 24000, 8000)
        self.assertAlmostEqual(self._rms(out) / self._rms(src), 1.0, delta=0.05)

    def test_downsample_rejects_aliasing_above_nyquist(self):
        # A 6 kHz tone cannot be represented at 8 kHz; without an anti-alias
        # filter it folds back into the audible band. It must be suppressed.
        src = self._tone(6000, 24000, secs=1.0)
        out = resample_pcm(src, 24000, 8000)
        self.assertLess(self._rms(out) / self._rms(src), 0.05)

    def test_non_integer_ratio_returns_expected_count(self):
        src = self._tone(1000, 22050, secs=1.0)
        out = resample_pcm(src, 22050, 8000)
        self.assertEqual(len(out), 8000)


class TestProviders(unittest.TestCase):
    def test_mock_produces_even_length_pcm(self):
        audio = MockTTSProvider().synthesize("hello world")
        self.assertGreater(len(audio), 0)
        self.assertEqual(len(audio) % 2, 0)

    def test_mock_duration_scales_with_text(self):
        short = len(MockTTSProvider().synthesize("hi"))
        long = len(MockTTSProvider().synthesize("hi " * 100))
        self.assertGreater(long, short)

    def test_mock_respects_sample_rate(self):
        provider = MockTTSProvider(sample_rate=16000)
        self.assertEqual(provider.sample_rate, 16000)

    def test_factory_defaults_to_mock(self):
        os.environ.pop("TTS_PROVIDER", None)
        self.assertIsInstance(get_provider(), MockTTSProvider)

    def test_factory_unknown_provider(self):
        with self.assertRaises(ProviderError):
            get_provider("nope")

    def test_command_provider_missing_binary_is_provider_error(self):
        provider = CommandTTSProvider("definitely-not-a-real-binary-xyz")
        with self.assertRaises(ProviderError):
            provider.synthesize("hi")

    def test_command_provider_converts_raw_pcm(self):
        provider = CommandTTSProvider("sh -c 'cat >/dev/null; head -c 16 /dev/zero'")
        self.assertEqual(provider.synthesize("hi"), b"\x00" * 16)


class TestServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = make_server("127.0.0.1", 0)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def _url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def test_health_endpoint(self):
        with urllib.request.urlopen(self._url("/health"), timeout=5) as resp:
            body = json.loads(resp.read())
        self.assertEqual(body["service"], "tts")

    def test_synthesize_returns_raw_pcm(self):
        req = urllib.request.Request(
            self._url("/v1/synthesize"),
            data=json.dumps({"text": "hello there"}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            audio = resp.read()
            self.assertEqual(resp.headers["Content-Type"], "audio/pcm")
            self.assertEqual(resp.headers["X-Sample-Format"], "s16be")
        self.assertGreater(len(audio), 0)
        self.assertEqual(len(audio) % 2, 0)

    def test_empty_text_is_bad_request(self):
        req = urllib.request.Request(
            self._url("/v1/synthesize"),
            data=json.dumps({"text": ""}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(ctx.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
