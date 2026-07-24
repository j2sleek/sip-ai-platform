# tts

**Runtime:** Python 3.14 · **Service name:** `tts`

## Purpose

Text-to-Speech service. Synthesizes agent responses into audio for the caller.

**Phase 1 scope:** foundation only — a health endpoint and a provider interface
(`synthesize(text) -> audio`) with a placeholder implementation. **No real TTS
synthesis and no model downloads.**

## How to run

Zero-dependency (standard library only):

```sh
cd services/tts
PYTHONPATH=src python3 -m tts.server      # http://127.0.0.1:5003/health
```

Environment: `TTS_HOST` (default `127.0.0.1`), `TTS_PORT` (default `5003`).

## How to test

```sh
cd services/tts
PYTHONPATH=src python3 -m unittest discover -s tests -v
# or, if pytest is installed:  PYTHONPATH=src pytest
```

## Health

`GET /health` →

```json
{ "status": "ok", "service": "tts", "version": "0.1.0" }
```

## Current limitations

- `synthesize()` raises `NotImplementedError` (placeholder).
- No model loading and no audio encoding.

## Future responsibilities

Real TTS (e.g. Piper, ONNX, CPU/ARM-friendly, offline) behind the `TTSProvider`
interface, added in the Python AI services phase.
