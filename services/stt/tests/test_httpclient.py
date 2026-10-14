"""Tests for the persistent-connection HTTP helper (stdlib unittest).

Runs against a loopback ``ThreadingHTTPServer`` — no network egress, no models.
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

from stt import httpclient  # noqa: E402


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    connections = 0
    requests = 0

    def setup(self):
        type(self).connections += 1
        super().setup()

    def do_GET(self):  # noqa: N802 (stdlib naming)
        type(self).requests += 1
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/echo")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self._json(200, {"ok": True})

    def do_POST(self):  # noqa: N802 (stdlib naming)
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length)
        type(self).requests += 1
        if self.path == "/echo":
            self._json(200, {"length": len(body), "ua": self.headers.get("User-Agent")})
        elif self.path == "/close":
            data = json.dumps({"ok": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True
        else:
            self._json(404, {"error": "not found"})

    def _json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):  # silence test output
        pass


class TestHttpClient(unittest.TestCase):
    def setUp(self):
        _Handler.connections = 0
        _Handler.requests = 0
        httpclient.close_all()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        httpclient.close_all()
        self.server.shutdown()
        self.server.server_close()

    def _post(self, path, body=b"{}", timeout=5):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        return httpclient.urlopen(request, timeout=timeout)

    def test_reuses_one_connection_for_sequential_requests(self):
        for _ in range(3):
            with self._post("/echo") as resp:
                payload = json.loads(resp.read())
        self.assertEqual(payload["length"], 2)
        self.assertEqual(_Handler.requests, 3)
        self.assertEqual(_Handler.connections, 1)

    def test_sends_default_user_agent(self):
        with self._post("/echo") as resp:
            payload = json.loads(resp.read())
        self.assertEqual(payload["ua"], httpclient.DEFAULT_USER_AGENT)

    def test_non_2xx_raises_httperror(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self._post("/missing")
        self.assertEqual(ctx.exception.code, 404)

    def test_redirect_is_followed(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.server.server_address[1]}/redirect", method="GET"
        )
        with httpclient.urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read())
        self.assertTrue(payload["ok"])

    def test_connection_close_response_is_not_pooled(self):
        with self._post("/close") as resp:
            resp.read()
        with self._post("/echo") as resp:
            resp.read()
        self.assertEqual(_Handler.connections, 2)

    def test_unreachable_origin_raises_urlerror(self):
        req = urllib.request.Request("http://127.0.0.1:1/x", data=b"{}", method="POST")
        with self.assertRaises(urllib.error.URLError):
            httpclient.urlopen(req, timeout=2)

    def test_retries_when_a_pooled_connection_is_stale(self):
        # Establish a pooled connection, then simulate a keep-alive timeout by
        # pulling the socket out from under the pooled connection.
        with self._post("/echo") as resp:
            resp.read()
        self.assertEqual(_Handler.connections, 1)

        origin = next(o for o in httpclient._origins.values() if o._idle)
        conn = origin._idle.pop()
        conn.sock.close()
        origin._idle.append(conn)

        with self._post("/echo") as resp:
            payload = json.loads(resp.read())
        self.assertEqual(payload["length"], 2)
        self.assertEqual(_Handler.connections, 2)

    def test_keepalive_can_be_disabled(self):
        original = os.environ.get("HTTP_KEEPALIVE")
        os.environ["HTTP_KEEPALIVE"] = "0"
        try:
            with self._post("/echo") as resp:
                resp.read()
            with self._post("/echo") as resp:
                resp.read()
        finally:
            if original is None:
                os.environ.pop("HTTP_KEEPALIVE", None)
            else:
                os.environ["HTTP_KEEPALIVE"] = original
        self.assertEqual(_Handler.connections, 2)


if __name__ == "__main__":
    unittest.main()
