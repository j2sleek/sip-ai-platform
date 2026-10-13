"""Tests for the stt service (stdlib unittest; pytest-discoverable).

Covers the provider interface, the mock provider, an external-command provider,
and the real HTTP server over loopback (no models, no network egress).
"""

import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import stt  # noqa: E402
from stt.health import health  # noqa: E402
from stt.provider import (  # noqa: E402
    CommandSTTProvider,
    MockSTTProvider,
    NotImplementedSTTProvider,
    STTProvider,
)
from stt.server import make_server  # noqa: E402


class TestFoundation(unittest.TestCase):
    def test_imports(self):
        self.assertEqual(stt.SERVICE_NAME, "stt")
        self.assertTrue(isinstance(stt.__version__, str))

    def test_health(self):
        payload = health()
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["service"], "stt")
        self.assertIn("version", payload)

    def test_provider_interface_exists(self):
        self.assertTrue(issubclass(NotImplementedSTTProvider, STTProvider))

    def test_placeholder_provider_raises(self):
        provider = NotImplementedSTTProvider()
        with self.assertRaises(NotImplementedError):
            provider.transcribe(b"\x00\x01")


class TestProviders(unittest.TestCase):
    def test_mock_returns_configured_text(self):
        provider = MockSTTProvider("book a meeting for tomorrow")
        self.assertEqual(provider.transcribe(b"\x00\x01" * 100), "book a meeting for tomorrow")

    def test_mock_empty_audio_is_empty_transcript(self):
        self.assertEqual(MockSTTProvider("x").transcribe(b""), "")

    def test_command_provider_reads_stdout(self):
        # A tiny shell pipeline stands in for a real STT binary.
        provider = CommandSTTProvider("sh -c 'cat >/dev/null; echo hello from command'")
        self.assertEqual(provider.transcribe(b"\x00\x01" * 10), "hello from command")

    def test_command_provider_missing_binary_is_provider_error(self):
        from stt.errors import ProviderError

        provider = CommandSTTProvider("definitely-not-a-real-binary-xyz")
        with self.assertRaises(ProviderError):
            provider.transcribe(b"\x00\x01")


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
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["service"], "stt")

    def test_transcribe_endpoint(self):
        pcm = b"\x00\x01" * 800  # 100 ms @ 8 kHz
        req = urllib.request.Request(
            self._url("/v1/transcribe?sample_rate=8000"),
            data=pcm,
            headers={"Content-Type": "audio/pcm", "X-Correlation-ID": "test-123"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read())
        self.assertIn("text", body)
        self.assertEqual(body["provider"], "mock")
        self.assertAlmostEqual(body["duration_ms"], 100.0, places=1)

    def test_empty_body_is_bad_request(self):
        req = urllib.request.Request(self._url("/v1/transcribe"), data=b"", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(ctx.exception.code, 400)

    def test_unknown_route_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(self._url("/nope"), timeout=5)
        self.assertEqual(ctx.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
