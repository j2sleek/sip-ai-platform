"""Structured errors shared by the stt service.

Every failure crossing the HTTP boundary is classified so callers can react
(see AGENTS.md → Failure Handling): `code` is a stable, machine-readable token.
"""

from __future__ import annotations


class ServiceError(Exception):
    """An error that maps to a structured HTTP error response."""

    status = 500
    code = "internal_error"

    def __init__(self, message: str, *, code: str | None = None, status: int | None = None):
        super().__init__(message)
        self.message = message
        if code is not None:
            self.code = code
        if status is not None:
            self.status = status

    def to_dict(self) -> dict:
        return {"error": {"code": self.code, "message": self.message}}


class BadRequest(ServiceError):
    status = 400
    code = "bad_request"


class PayloadTooLarge(ServiceError):
    status = 413
    code = "payload_too_large"


class Overloaded(ServiceError):
    status = 503
    code = "overloaded"


class ProviderError(ServiceError):
    """A failure inside an inference provider (dependency/transient)."""

    status = 502
    code = "provider_error"
