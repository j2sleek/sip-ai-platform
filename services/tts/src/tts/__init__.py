"""tts — Text-to-Speech service for the SIP AI Platform.

Provides `POST /v1/synthesize` (text in → raw PCM audio out) behind a swappable
`TTSProvider` interface, plus `GET /health`.

The default provider is a dependency-free mock that emits a deterministic tone,
so the platform is audible end-to-end without a model; a local Piper command
adapter is available via `TTS_PROVIDER=command`.

Audio wire format: 16-bit signed PCM, big-endian, mono — matching the
AudioSocket media transport used by the Elixir core.

No model weights are bundled or downloaded by this service.
"""

__version__ = "0.2.0"
SERVICE_NAME = "tts"
