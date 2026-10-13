"""Tests for the vad service (stdlib unittest; pytest-discoverable)."""

import base64
import json
import os
import struct
import sys
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import vad  # noqa: E402
from vad.health import health  # noqa: E402
from vad.provider import EnergyVADProvider, get_provider  # noqa: E402
from vad.server import make_server  # noqa: E402


def be_pcm(values):
    return b"".join(struct.pack(">h", v) for v in values)


class TestFoundation(unittest.TestCase):
    def test_imports(self):
        self.assertEqual(vad.SERVICE_NAME, "vad")
        self.assertTrue(isinstance(vad.__version__, str))

    def test_health(self):
        payload = health()
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["service"], "vad")


class TestEnergyProvider(unittest.TestCase):
    def setUp(self):
        self.provider = EnergyVADProvider()

    def test_silence_is_not_speech(self):
        result = self.provider.analyze(be_pcm([0] * 800), 8000, 300.0, "pcm_s16be")
        self.assertFalse(result["speech"])
        self.assertEqual(result["rms"], 0.0)
        self.assertAlmostEqual(result["duration_ms"], 100.0, places=1)

    def test_constant_signal_is_speech(self):
        result = self.provider.analyze(be_pcm([2000] * 800), 8000, 300.0, "pcm_s16be")
        self.assertTrue(result["speech"])
        self.assertAlmostEqual(result["rms"], 2000.0, places=1)

    def test_little_endian_decoding(self):
        data = b"".join(struct.pack("<h", 2000) for _ in range(800))
        result = self.provider.analyze(data, 8000, 300.0, "pcm_s16le")
        self.assertTrue(result["speech"])

    def test_empty_audio(self):
        result = self.provider.analyze(b"", 8000, 300.0, "pcm_s16be")
        self.assertFalse(result["speech"])
        self.assertEqual(result["samples"], 0)

    def test_factory_defaults_to_energy(self):
        os.environ.pop("VAD_PROVIDER", None)
        self.assertIsInstance(get_provider(), EnergyVADProvider)

    def test_factory_unknown_provider(self):
        with self.assertRaises(ValueError):
            get_provider("nope")


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
        self.assertEqual(body["service"], "vad")

    def test_analyze_raw_pcm(self):
        req = urllib.request.Request(
            self._url("/v1/analyze?sample_rate=8000&threshold=300"),
            data=be_pcm([2000] * 800),
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read())
        self.assertTrue(body["speech"])
        self.assertEqual(body["provider"], "energy")

    def test_analyze_json_base64(self):
        payload = json.dumps({"pcm": base64.b64encode(be_pcm([0] * 800)).decode()}).encode()
        req = urllib.request.Request(
            self._url("/v1/analyze"),
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read())
        self.assertFalse(body["speech"])

    def test_empty_body_is_bad_request(self):
        req = urllib.request.Request(self._url("/v1/analyze"), data=b"", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(ctx.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
