"""Tests for the llm service (stdlib unittest; pytest-discoverable).

Covers the provider interface, the mock and Ollama adapters (with a local stub
server standing in for Ollama), and the real HTTP server over loopback.
"""

import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import llm  # noqa: E402
from llm.errors import ProviderError  # noqa: E402
from llm.health import health  # noqa: E402
from llm.provider import (  # noqa: E402
    LLMProvider,
    MockLLMProvider,
    NotImplementedLLMProvider,
    OllamaLLMProvider,
    get_provider,
)
from llm.server import make_server  # noqa: E402


class _StubOllama(BaseHTTPRequestHandler):
    """Minimal fake Ollama daemon for adapter tests."""

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        _ = self.rfile.read(length)
        body = json.dumps({"message": {"role": "assistant", "content": "from ollama"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


class TestFoundation(unittest.TestCase):
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


class TestProviders(unittest.TestCase):
    def test_mock_echoes_last_user_message(self):
        provider = MockLLMProvider()
        result = provider.generate(
            [
                {"role": "system", "content": "be nice"},
                {"role": "user", "content": "call alice"},
            ]
        )
        self.assertEqual(result["role"], "assistant")
        self.assertIn("call alice", result["content"])

    def test_mock_honours_configured_reply(self):
        os.environ["LLM_MOCK_REPLY"] = "fixed reply"
        try:
            self.assertEqual(MockLLMProvider().generate([])["content"], "fixed reply")
        finally:
            del os.environ["LLM_MOCK_REPLY"]

    def test_factory_defaults_to_mock(self):
        os.environ.pop("LLM_PROVIDER", None)
        self.assertIsInstance(get_provider(), MockLLMProvider)

    def test_factory_unknown_provider(self):
        with self.assertRaises(ProviderError):
            get_provider("nope")

    def test_ollama_adapter_parses_chat_response(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), _StubOllama)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_address[1]}"
            provider = OllamaLLMProvider(base, "stub-model", timeout_s=5)
            result = provider.generate([{"role": "user", "content": "hi"}])
            self.assertEqual(result["content"], "from ollama")
        finally:
            server.shutdown()
            server.server_close()


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

    def _post(self, path, payload):
        req = urllib.request.Request(
            self._url(path),
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())

    def test_health_endpoint(self):
        with urllib.request.urlopen(self._url("/health"), timeout=5) as resp:
            body = json.loads(resp.read())
        self.assertEqual(body["service"], "llm")

    def test_generate_with_messages(self):
        body = self._post(
            "/v1/generate",
            {"messages": [{"role": "user", "content": "hello there"}]},
        )
        self.assertIn("hello there", body["response"])
        self.assertEqual(body["provider"], "mock")

    def test_generate_with_prompt(self):
        body = self._post("/v1/generate", {"prompt": "summarise"})
        self.assertIn("summarise", body["response"])

    def test_missing_messages_is_bad_request(self):
        req = urllib.request.Request(
            self._url("/v1/generate"),
            data=json.dumps({}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(ctx.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
