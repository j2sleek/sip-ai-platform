"""Tests for the llm service foundation (stdlib unittest; pytest-discoverable)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import llm  # noqa: E402
from llm.health import health  # noqa: E402
from llm.provider import LLMProvider, NotImplementedLLMProvider  # noqa: E402


class TestLlm(unittest.TestCase):
    def test_imports(self):
        self.assertEqual(llm.SERVICE_NAME, "llm")
        self.assertTrue(isinstance(llm.__version__, str))

    def test_health(self):
        payload = health()
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["service"], "llm")
        self.assertIn("version", payload)

    def test_provider_interface_exists(self):
        self.assertTrue(issubclass(NotImplementedLLMProvider, LLMProvider))

    def test_placeholder_provider_raises(self):
        provider = NotImplementedLLMProvider()
        with self.assertRaises(NotImplementedError):
            provider.generate([{"role": "user", "content": "hi"}])


if __name__ == "__main__":
    unittest.main()
