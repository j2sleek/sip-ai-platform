# stt

**Runtime:** Python 3.14 (stdlib only) · **Service name:** `stt`

## Purpose

Speech-to-Text service. Converts inbound call audio into text for the agent.

It exposes `POST /v1/transcribe` (raw PCM in → text out) behind a swappable
`STTProvider` interface, plus `GET /health`. The default provider is a
dependency-free **mock** so the platform runs end-to-end without a model; real
backends (whisper.cpp, faster-whisper) are invoked as external commands.

## How to run

Zero-dependency (standard library only):

```sh
cd services/stt
PYTHONPATH=src python3 -m stt.server      # http://127.0.0.1:5001
```

Environment: `STT_HOST` (default `127.0.0.1`), `STT_PORT` (default `5001`),
`STT_PROVIDER` (`mock` | `command`). See `.env.example` for all options.

## API

`POST /v1/transcribe?sample_rate=8000&encoding=pcm_s16be`
body = raw 16-bit PCM → `{"text", "provider", "duration_ms"}`

```sh
printf '\x00\x01%.0s' {1..800} | \
  curl -sS --data-binary @- 'http://127.0.0.1:5001/v1/transcribe'
```

`GET /health` → `{ "status": "ok", "service": "stt", "version": "0.2.0" }`

Errors are structured: `{"error": {"code": "...", "message": "..."}}` with an
appropriate status (400/413/502/503/500).

## How to test

```sh
cd services/stt
PYTHONPATH=src python3 -m unittest discover -s tests -v
# or, if pytest is installed:  PYTHONPATH=src pytest
```

## Real providers

`STT_PROVIDER=command` runs an external binary with PCM on stdin and the
transcript on stdout, e.g.:

```sh
STT_PROVIDER=command \
STT_COMMAND="whisper-cli -m /models/ggml-base.en.bin -f - -nt -np" \
PYTHONPATH=src python3 -m stt.server
```

## Current limitations

- No model weights are bundled or downloaded by this service.
- `command` provider: no resampling; feed audio at the backend's expected rate.
- Telephony wire format is 16-bit PCM; no compression (μ-law/A-law) yet.

## Related

- Contracts: `packages/contracts` (AudioChunk, HealthResponse).
- Caller: Elixir `VoiceCore.AI.transcribe/2`.
