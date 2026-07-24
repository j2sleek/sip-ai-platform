"""Tests for the stt service foundation (stdlib unittest; pytest-discoverable)."""

import os
import sys
import unittest

# Make src/ importable without installation.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import stt  # noqa: E402
from stt.health import health  # noqa: E402
from stt.provider import NotImplementedSTTProvider, STTProvider  # noqa: E402


class TestStt(unittest.TestCase):
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
            provider.transcribe(b"")


if __name__ == "__main__":
    unittest.main()
