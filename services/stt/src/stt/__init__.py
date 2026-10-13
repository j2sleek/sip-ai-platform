"""stt — Speech-to-Text service for the SIP AI Platform.

Provides `POST /v1/transcribe` (raw PCM in → text out) behind a swappable
`STTProvider` interface, plus `GET /health`. The default provider is a
dependency-free mock so the service runs anywhere; real providers (whisper.cpp,
faster-whisper) are wired via environment variables.

No model weights are bundled or downloaded by this service.
"""

__version__ = "0.2.0"
SERVICE_NAME = "stt"
