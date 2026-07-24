"""Minimal stdlib HTTP server exposing GET /health for the tts service.

Standard library only, so it runs with zero installed dependencies.

Run:
    python -m tts.server            # binds TTS_HOST:TTS_PORT (default 127.0.0.1:5003)
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .health import health


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        if self.path == "/health":
            body = json.dumps(health()).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404, "not found")

    def log_message(self, fmt: str, *args) -> None:
        return


def make_server(host: str | None = None, port: int | None = None) -> ThreadingHTTPServer:
    host = host or os.environ.get("TTS_HOST", "127.0.0.1")
    port = port or int(os.environ.get("TTS_PORT", "5003"))
    return ThreadingHTTPServer((host, port), _Handler)


def main() -> None:
    server = make_server()
    host, port = server.server_address
    print(f"tts health server listening on http://{host}:{port}/health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
