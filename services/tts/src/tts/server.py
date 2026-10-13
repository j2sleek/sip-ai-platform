"""HTTP server for the tts service (standard library only).

Endpoints:

  * ``GET  /health``       — HealthResponse contract
  * ``POST /v1/synthesize`` — body: ``{"text": "..."}``
                              → raw 16-bit big-endian PCM (``audio/pcm``)

The response is raw PCM (not JSON) because that is what the Elixir core and the
AudioSocket media transport consume. Sample rate/format are advertised in the
``X-Sample-Rate`` and ``X-Sample-Format`` headers.

Every request is bounded by a concurrency semaphore and produces structured
JSON logs with an optional ``X-Correlation-ID``.

Run:
    python -m tts.server            # binds TTS_HOST:TTS_PORT (default 127.0.0.1:5003)
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import SERVICE_NAME, __version__
from .errors import BadRequest, Overloaded, PayloadTooLarge, ServiceError
from .health import health
from .provider import get_provider

MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(1 * 1024 * 1024)))
MAX_CONCURRENT = int(os.environ.get("TTS_MAX_CONCURRENT", "4"))
MAX_TEXT_CHARS = int(os.environ.get("TTS_MAX_TEXT_CHARS", "4000"))

logger = logging.getLogger(SERVICE_NAME)

_slots = threading.BoundedSemaphore(MAX_CONCURRENT)

_provider = None
_provider_lock = threading.Lock()


def _get_provider():
    global _provider
    if _provider is None:
        with _provider_lock:
            if _provider is None:
                _provider = get_provider()
    return _provider


def _log(level: int, event: str, correlation_id: str | None = None, **fields) -> None:
    record = {"service": SERVICE_NAME, "event": event}
    if correlation_id:
        record["correlation_id"] = correlation_id
    record.update(fields)
    logger.log(level, json.dumps(record))


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"{SERVICE_NAME}/{__version__}"

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        if self.path.split("?", 1)[0] == "/health":
            self._send_json(200, health())
        else:
            self._send_json(404, {"error": {"code": "not_found", "message": "not found"}})

    def do_POST(self) -> None:  # noqa: N802 (stdlib naming)
        path = self.path.split("?", 1)[0]
        try:
            if path == "/v1/synthesize":
                self._handle_synthesize()
            else:
                self._send_json(404, {"error": {"code": "not_found", "message": "not found"}})
        except ServiceError as exc:
            _log(logging.WARNING, "request_error", self._correlation_id(), code=exc.code)
            self._send_json(exc.status, exc.to_dict())
        except Exception:  # noqa: BLE001 — never leak internals
            _log(logging.ERROR, "unhandled_error", self._correlation_id())
            logger.exception("unhandled error")
            self._send_json(
                500, {"error": {"code": "internal_error", "message": "internal error"}}
            )

    def _handle_synthesize(self) -> None:
        if not _slots.acquire(blocking=False):
            raise Overloaded("too many concurrent requests")

        try:
            raw = self._read_body()
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise BadRequest("body must be valid JSON") from exc
            if not isinstance(payload, dict):
                raise BadRequest("body must be a JSON object")

            text = payload.get("text")
            if not isinstance(text, str) or not text.strip():
                raise BadRequest("'text' must be a non-empty string")
            if len(text) > MAX_TEXT_CHARS:
                raise PayloadTooLarge(f"'text' exceeds {MAX_TEXT_CHARS} characters")

            provider = _get_provider()
            started = time.perf_counter()
            audio = provider.synthesize(text)
            elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

            _log(
                logging.INFO,
                "synthesize",
                self._correlation_id(),
                provider=provider.name,
                sample_rate=provider.sample_rate,
                text_chars=len(text),
                audio_bytes=len(audio),
                elapsed_ms=elapsed_ms,
            )

            self.send_response(200)
            self.send_header("Content-Type", "audio/pcm")
            self.send_header("Content-Length", str(len(audio)))
            self.send_header("X-Sample-Rate", str(provider.sample_rate))
            self.send_header("X-Sample-Format", "s16be")
            self.end_headers()
            self.wfile.write(audio)
        finally:
            _slots.release()

    # ─── helpers ───────────────────────────────────────────────────────────────

    def _correlation_id(self) -> str | None:
        return self.headers.get("X-Correlation-ID")

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return b""
        if length > MAX_BODY_BYTES:
            raise PayloadTooLarge(f"body exceeds {MAX_BODY_BYTES} bytes")

        chunks: list[bytes] = []
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:  # silence default access log
        return


def make_server(host: str | None = None, port: int | None = None) -> ThreadingHTTPServer:
    host = host or os.environ.get("TTS_HOST", "127.0.0.1")
    port = port if port is not None else int(os.environ.get("TTS_PORT", "5003"))
    server = ThreadingHTTPServer((host, port), _Handler)
    server.daemon_threads = True
    return server


def main() -> None:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "info").upper())
    server = make_server()
    addr_host, addr_port = server.server_address
    _log(logging.INFO, "listening", host=addr_host, port=addr_port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
