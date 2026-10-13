"""vad — Voice Activity Detection service for the SIP AI Platform.

Provides `POST /v1/analyze` (raw PCM in → speech/energy analysis out) behind a
swappable `VADProvider` interface, plus `GET /health`.

The default provider is a dependency-free energy (RMS) detector. It is useful for
callers that want a second opinion on endpointing, or for services that prefer to
delegate VAD over HTTP instead of running it in-process (the Elixir core runs its
own pure energy VAD in `VoiceCore.VoiceAgent.Turn`).

No model weights are bundled or downloaded by this service.
"""

__version__ = "0.1.0"
SERVICE_NAME = "vad"
