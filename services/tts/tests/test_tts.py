"""Tests for the tts service foundation (stdlib unittest; pytest-discoverable)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import tts  # noqa: E402
from tts.health import health  # noqa: E402
from tts.provider import NotImplementedTTSProvider, TTSProvider  # noqa: E402


class TestTts(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
