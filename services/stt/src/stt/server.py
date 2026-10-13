"""HTTP server for the stt service (standard library only).

Endpoints:

  * ``GET  /health``         — HealthResponse contract
  * ``POST /v1/transcribe``  — body: raw PCM (query ``sample_rate``, ``encoding``)
                               → ``{"text", "provider", "duration_ms"}``

Every request is bounded by a concurrency semaphore and produces structured
JSON logs with an optional ``X-Correlation-ID``. Failures are classified
(``errors.ServiceError``) and returned as structured JSON.

Run:
    python -m stt.server            # binds STT_HOST:STT_PORT (default 127.0.0.1:5001)
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

MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(16 * 1024 * 1024)))
MAX_CONCURRENT = int(os.environ.get("STT_MAX_CONCURRENT", "8"))

logger = logging.getLogger(SERVICE_NAME)

# Bound concurrent inference requests; excess load is rejected with 503 rather
# than queued without limit (keeps latency predictable under load).
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

    # ─── routing ───────────────────────────────────────────────────────────────

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        if self.path.split("?", 1)[0] == "/health":
            self._send_json(200, health())
        else:
            self._send_json(404, {"error": {"code": "not_found", "message": "not found"}})

    def do_POST(self) -> None:  # noqa: N802 (stdlib naming)
        path = self.path.split("?", 1)[0]
        try:
            if path == "/v1/transcribe":
                self._handle_transcribe()
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

    def _handle_transcribe(self) -> None:
        if not _slots.acquire(blocking=False):
            raise Overloaded("too many concurrent requests")

        try:
            params = _parse_query(self.path)
            audio = self._read_body()
            if not audio:
                raise BadRequest("empty audio body")

            sample_rate = int(params.get("sample_rate", "8000"))
            started = time.perf_counter()
            text = _get_provider().transcribe(audio, sample_rate)
            elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

            _log(
                logging.INFO,
                "transcribe",
                self._correlation_id(),
                bytes=len(audio),
                sample_rate=sample_rate,
                provider=_get_provider().name,
                text_chars=len(text),
                elapsed_ms=elapsed_ms,
            )

            self._send_json(
                200,
                {
                    "text": text,
                    "provider": _get_provider().name,
                    "duration_ms": round(len(audio) / 2 / sample_rate * 1000, 3),
                },
            )
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


def _parse_query(path: str) -> dict[str, str]:
    from urllib.parse import parse_qs, urlparse

    query = urlparse(path).query
    return {k: v[0] for k, v in parse_qs(query).items()}


def make_server(host: str | None = None, port: int | None = None) -> ThreadingHTTPServer:
    host = host or os.environ.get("STT_HOST", "127.0.0.1")
    port = port if port is not None else int(os.environ.get("STT_PORT", "5001"))
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
