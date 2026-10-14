"""Persistent-connection HTTP helper for the cloud providers.

`urllib.request.urlopen` opens a fresh TCP (and, for HTTPS, TLS) connection for
every request and drops it as soon as the response is read. A single voice turn
makes an STT, an LLM and a TTS request in quick succession, so paying DNS + TCP
+ TLS setup on every one of them adds up over a mobile uplink.

This module keeps a small pool of idle keep-alive connections per origin and
reuses them. It exposes ``urlopen(request, timeout)`` with the same call shape
the providers already use::

    with urlopen(request, timeout) as resp:
        body = resp.read()

Non-2xx responses raise ``urllib.error.HTTPError`` and connection failures raise
``urllib.error.URLError`` — exactly like ``urllib.request.urlopen`` — so callers
need no changes. Set ``HTTP_KEEPALIVE=0` to fall back to plain urllib, which is
also done automatically when an HTTP proxy is configured (proxies are not
pooled here).
"""

from __future__ import annotations

import http.client
import io
import os
import threading
import urllib.error
import urllib.request
from urllib.parse import urljoin, urlsplit

# Cloudflare (fronting Groq/OpenRouter) rejects the default python-urllib
# User-Agent with HTTP 403 / error 1010, so every request carries an explicit UA.
DEFAULT_USER_AGENT = "sip-ai-platform/0.2.0"

# Idle keep-alive connections retained per origin (scheme+host+port).
MAX_IDLE_PER_ORIGIN = int(os.environ.get("HTTP_MAX_IDLE", "8"))

_REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})
_MAX_REDIRECTS = 3


class _Response:
    """Minimal urllib-compatible response over an in-memory body.

    The body is always fully read before the connection is returned to the pool,
    so this simply replays the bytes to the caller.
    """

    def __init__(self, status: int, headers, body: bytes, url: str) -> None:
        self.status = status
        self.headers = headers
        self.url = url
        self._body = body
        self._pos = 0

    def read(self, amt: int | None = None) -> bytes:
        if amt is None:
            data = self._body[self._pos :]
            self._pos = len(self._body)
        else:
            data = self._body[self._pos : self._pos + amt]
            self._pos += len(data)
        return data

    def __enter__(self) -> "_Response":
        return self

    def __exit__(self, *_exc) -> bool:
        return False


class _Origin:
    """A pool of idle keep-alive connections to one scheme://host:port."""

    def __init__(self, scheme: str, host: str, port: int) -> None:
        self.scheme = scheme
        self.host = host
        self.port = port
        self._idle: list = []
        self._lock = threading.Lock()

    def new_connection(self, timeout: float):
        cls = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        return cls(self.host, self.port, timeout=timeout)

    def acquire(self, timeout: float, fresh: bool = False):
        if not fresh:
            with self._lock:
                if self._idle:
                    return self._idle.pop()
        return self.new_connection(timeout)

    def release(self, conn, reusable: bool) -> None:
        if reusable:
            with self._lock:
                if len(self._idle) < MAX_IDLE_PER_ORIGIN:
                    self._idle.append(conn)
                    return
        try:
            conn.close()
        except Exception:  # noqa: BLE001 — best-effort cleanup
            pass

    def close(self) -> None:
        with self._lock:
            idle, self._idle = self._idle, []
        for conn in idle:
            try:
                conn.close()
            except Exception:  # noqa: BLE001 — best-effort cleanup
                pass


_origins: dict[tuple[str, str, int], _Origin] = {}
_origins_lock = threading.Lock()


def _origin_for(scheme: str, host: str, port: int) -> _Origin:
    key = (scheme, host, port)
    with _origins_lock:
        origin = _origins.get(key)
        if origin is None:
            origin = _origins[key] = _Origin(scheme, host, port)
        return origin


def close_all() -> None:
    """Closes every pooled idle connection (used by tests and shutdown)."""
    with _origins_lock:
        origins = list(_origins.values())
    for origin in origins:
        origin.close()


def _keepalive_enabled() -> bool:
    value = os.environ.get("HTTP_KEEPALIVE", "1").strip().lower()
    return value not in {"0", "false", "no", "off"}


def _proxy_configured(url: str) -> bool:
    scheme = urlsplit(url).scheme
    try:
        proxies = urllib.request.getproxies()
    except Exception:  # noqa: BLE001 — environment lookup must never fail the request
        return False
    return bool(proxies.get(scheme) or proxies.get("all"))


def _is_retryable(exc: BaseException) -> bool:
    """True for failures that mean a pooled connection was already dead.

    A timeout is *not* retried: the request may be mid-flight server-side.
    """
    if isinstance(exc, TimeoutError):
        return False
    return isinstance(exc, http.client.HTTPException) or isinstance(exc, OSError)


def _wrap(exc: BaseException) -> BaseException:
    """Maps low-level failures onto the exceptions urllib would raise."""
    if isinstance(exc, (urllib.error.URLError, TimeoutError)):
        return exc
    return urllib.error.URLError(exc)


def _split(url: str) -> tuple[str, str, int, str]:
    parts = urlsplit(url)
    scheme = parts.scheme or "http"
    host = parts.hostname
    if not host:
        raise urllib.error.URLError(f"no host in URL: {url!r}")
    try:
        port = parts.port
    except ValueError:
        port = None
    if port is None:
        port = 443 if scheme == "https" else 80
    target = parts.path or "/"
    if parts.query:
        target = f"{target}?{parts.query}"
    return scheme, host, port, target


def _exchange(url: str, method: str, body, headers: dict, timeout: float):
    """Performs one request, retrying once on a stale pooled connection."""
    scheme, host, port, target = _split(url)
    origin = _origin_for(scheme, host, port)

    for attempt in (0, 1):
        conn = origin.acquire(timeout, fresh=attempt > 0)
        try:
            conn.request(method, target, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            status = resp.status
            resp_headers = resp.headers
            reusable = not resp.will_close
        except BaseException as exc:  # noqa: BLE001 — re-raised below
            origin.release(conn, reusable=False)
            if attempt == 0 and _is_retryable(exc):
                continue
            raise _wrap(exc) from exc
        origin.release(conn, reusable=reusable)
        return status, resp_headers, data

    raise urllib.error.URLError("request failed")  # pragma: no cover — loop always returns/raises


def urlopen(request: urllib.request.Request, timeout: float):
    """urlopen with a stable User-Agent and pooled keep-alive connections."""
    url = request.full_url

    if not _keepalive_enabled() or _proxy_configured(url):
        if not request.has_header("User-agent"):
            request.add_header("User-Agent", DEFAULT_USER_AGENT)
        return urllib.request.urlopen(request, timeout=timeout)

    method = request.get_method()
    body = request.data
    headers = dict(request.header_items())
    headers.setdefault("User-Agent", DEFAULT_USER_AGENT)

    for redirects in range(_MAX_REDIRECTS + 1):
        status, resp_headers, data = _exchange(url, method, body, headers, timeout)

        if status in _REDIRECT_STATUSES and redirects < _MAX_REDIRECTS:
            location = resp_headers.get("Location") if resp_headers else None
            if location:
                url = urljoin(url, location)
                # Match urllib: 301/302/303 become GET without a body; 307/308
                # preserve the method and body.
                if status in (301, 302, 303):
                    method = "HEAD" if method == "HEAD" else "GET"
                    body = None
                    headers.pop("Content-type", None)
                    headers.pop("Content-length", None)
                continue

        if not 200 <= status < 300:
            reason = http.client.responses.get(status, "")
            raise urllib.error.HTTPError(url, status, reason, resp_headers, io.BytesIO(data))

        return _Response(status, resp_headers, data, url)

    raise urllib.error.HTTPError(url, 310, "too many redirects", None, io.BytesIO(b""))
