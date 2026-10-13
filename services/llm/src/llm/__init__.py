"""llm — LLM inference service for the SIP AI Platform.

Provides `POST /v1/generate` (chat messages in → assistant response out) behind a
swappable `LLMProvider` interface, plus `GET /health`.

The default provider is a dependency-free mock so the platform runs end-to-end
without a model; a local Ollama adapter is available via `LLM_PROVIDER=ollama`.

No model weights are bundled or downloaded by this service.
"""

__version__ = "0.2.0"
SERVICE_NAME = "llm"
