# tts

**Runtime:** Python 3.14 (stdlib only) · **Service name:** `tts`

## Purpose

Text-to-Speech service. Synthesizes agent responses into audio for the caller.

It exposes `POST /v1/synthesize` (text in → raw PCM out) behind a swappable
`TTSProvider` interface, plus `GET /health`. The default provider is a
dependency-free **mock** tone; a local **Piper** command adapter is selected with
`TTS_PROVIDER=command`.

Audio wire format: **16-bit signed PCM, big-endian, mono** — matching the
AudioSocket media transport used by the Elixir core.

## How to run

Zero-dependency (standard library only):

```sh
cd services/tts
PYTHONPATH=src python3 -m tts.server      # http://127.0.0.1:5003
```

Environment: `TTS_HOST` (default `127.0.0.1`), `TTS_PORT` (default `5003`),
`TTS_PROVIDER` (`mock` | `command` | `piper`), `TTS_SAMPLE_RATE` (default `8000`).
See `.env.example` for all options.

## API

`POST /v1/synthesize` body `{"text": "hello"}` → `audio/pcm` (raw bytes), with
headers `X-Sample-Rate` and `X-Sample-Format: s16be`.

```sh
curl -sS -H 'Content-Type: application/json' \
  -d '{"text":"hello"}' http://127.0.0.1:5003/v1/synthesize -o out.pcm
```

`GET /health` → `{ "status": "ok", "service": "tts", "version": "0.2.0" }`

Errors are structured JSON: `{"error": {"code": "...", "message": "..."}}`.

## How to test

```sh
cd services/tts
PYTHONPATH=src python3 -m unittest discover -s tests -v
# or, if pytest is installed:  PYTHONPATH=src pytest
```

## Real providers

```sh
TTS_PROVIDER=command \
TTS_COMMAND="piper --model /models/en_US-lessac-medium.onnx --output-raw" \
PYTHONPATH=src python3 -m tts.server
```

The command reads text on stdin and writes raw 16-bit little-endian PCM on
stdout; the service re-encodes it to big-endian for the wire.

## Current limitations

- No model weights are bundled or downloaded by this service.
- No sample-rate conversion — configure `TTS_SAMPLE_RATE` to match the model.
- No streaming synthesis yet; the whole utterance is synthesized per call.

## Related

- Contracts: `packages/contracts` (AudioChunk, HealthResponse).
- Caller: Elixir `VoiceCore.AI.synthesize/2`.
