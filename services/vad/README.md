# vad

**Runtime:** Python 3.14 (stdlib only) · **Service name:** `vad`

## Purpose

Voice Activity Detection service. Reports whether a PCM buffer contains speech
and its energy, behind a swappable `VADProvider` interface, plus `GET /health`.

The default provider is a dependency-free **energy (RMS)** detector. The Elixir
core runs its own pure energy VAD in `VoiceCore.VoiceAgent.Turn`; this service
exists for callers (e.g. the MCP control plane, offline tooling) that prefer to
delegate VAD over HTTP, and as a home for heavier models later.

## How to run

Zero-dependency (standard library only):

```sh
cd services/vad
PYTHONPATH=src python3 -m vad.server      # http://127.0.0.1:5004
```

Environment: `VAD_HOST` (default `127.0.0.1`), `VAD_PORT` (default `5004`),
`VAD_PROVIDER` (`energy`). See `.env.example` for all options.

## API

`POST /v1/analyze` — two input forms:

- **raw PCM** with query params:
  `?sample_rate=8000&threshold=300&encoding=pcm_s16be`
- **JSON base64**: `{"pcm": "<base64>", "sample_rate": 8000, "threshold": 300}`

Response:

```json
{
  "speech": true,
  "rms": 2000.0,
  "energy_db": -24.28,
  "samples": 800,
  "duration_ms": 100.0,
  "threshold": 300.0,
  "provider": "energy",
  "encoding": "pcm_s16be"
}
```

`GET /health` → `{ "status": "ok", "service": "vad", "version": "0.1.0" }`

Errors are structured JSON: `{"error": {"code": "...", "message": "..."}}`.

## How to test

```sh
cd services/vad
PYTHONPATH=src python3 -m unittest discover -s tests -v
# or, if pytest is installed:  PYTHONPATH=src pytest
```

## Current limitations

- Energy-based only; no ML VAD (Silero etc.) yet.
- No resampling or compression; input is 16-bit PCM.

## Related

- Contracts: `packages/contracts` (AudioChunk, HealthResponse).
