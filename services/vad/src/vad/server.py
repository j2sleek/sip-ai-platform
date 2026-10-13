"""HTTP server for the vad service (standard library only).

Endpoints:

  * ``GET  /health``     — HealthResponse contract
  * ``POST /v1/analyze`` — analyze a PCM buffer for speech/energy.

Input forms:

  * raw PCM with query params (default): ``?sample_rate=8000&threshold=300&encoding=pcm_s16be``
  * JSON with base64 PCM: ``{"pcm": "<base64>", "sample_rate": 8000, ...}``
    (Content-Type: application/json)

Output: ``{"speech", "rms", "energy_db", "samples", "duration_ms", "threshold",
"provider"}``.

Run:
    python -m vad.server            # binds VAD_HOST:VAD_PORT (default 127.0.0.1:5004)
"""

from __future__ import annotations

import base64
import binascii
import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import SERVICE_NAME, __version__
from .errors import BadRequest, Overloaded, PayloadTooLarge, ServiceError
from .health import health
from .provider import DEFAULT_SAMPLE_RATE, DEFAULT_THRESHOLD, get_provider

MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(16 * 1024 * 1024)))
MAX_CONCURRENT = int(os.environ.get("VAD_MAX_CONCURRENT", "8"))

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
            if path == "/v1/analyze":
                self._handle_analyze()
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

    def _handle_analyze(self) -> None:
        if not _slots.acquire(blocking=False):
            raise Overloaded("too many concurrent requests")

        try:
            raw = self._read_body()
            params = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}

            content_type = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip()
            if content_type == "application/json":
                audio, params = self._parse_json_body(raw, params)
            else:
                audio = raw

            if not audio:
                raise BadRequest("empty audio body")

            try:
                sample_rate = int(params.get("sample_rate", str(DEFAULT_SAMPLE_RATE)))
                threshold = float(params.get("threshold", str(DEFAULT_THRESHOLD)))
            except ValueError as exc:
                raise BadRequest("invalid sample_rate/threshold") from exc
            encoding = params.get("encoding", "pcm_s16be")

            started = time.perf_counter()
            result = _get_provider().analyze(audio, sample_rate, threshold, encoding)
            elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

            _log(
                logging.INFO,
                "analyze",
                self._correlation_id(),
                bytes=len(audio),
                speech=result["speech"],
                rms=result["rms"],
                elapsed_ms=elapsed_ms,
            )

            result["provider"] = _get_provider().name
            result["encoding"] = encoding
            self._send_json(200, result)
        finally:
            _slots.release()

    def _parse_json_body(self, raw: bytes, params: dict) -> tuple[bytes, dict]:
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise BadRequest("body must be valid JSON") from exc
        if not isinstance(payload, dict) or "pcm" not in payload:
            raise BadRequest("JSON body must contain 'pcm' (base64)")

        try:
            audio = base64.b64decode(payload["pcm"], validate=True)
        except (binascii.Error, ValueError) as exc:
            raise BadRequest("'pcm' must be valid base64") from exc

        for key in ("sample_rate", "threshold", "encoding"):
            if key in payload:
                params[key] = str(payload[key])
        return audio, params

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
    host = host or os.environ.get("VAD_HOST", "127.0.0.1")
    port = port if port is not None else int(os.environ.get("VAD_PORT", "5004"))
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
