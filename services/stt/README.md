# stt

**Runtime:** Python 3.14 · **Service name:** `stt`

## Purpose

Speech-to-Text service. Converts inbound call audio into text for the agent.

**Phase 1 scope:** foundation only — a health endpoint and a provider interface
(`transcribe(audio) -> text`) with a placeholder implementation. **No real STT
inference and no model downloads.**

## How to run

Zero-dependency (standard library only):

```sh
cd services/stt
PYTHONPATH=src python3 -m stt.server      # http://127.0.0.1:5001/health
```

Environment: `STT_HOST` (default `127.0.0.1`), `STT_PORT` (default `5001`).

## How to test

```sh
cd services/stt
PYTHONPATH=src python3 -m unittest discover -s tests -v
# or, if pytest is installed:  PYTHONPATH=src pytest
```

## Health

`GET /health` →

```json
{ "status": "ok", "service": "stt", "version": "0.1.0" }
```

## Current limitations

- `transcribe()` raises `NotImplementedError` (placeholder).
- No audio decoding, VAD, or model loading.

## Future responsibilities

Real STT (e.g. faster-whisper, int8, CPU/ARM-friendly) behind the `STTProvider`
interface, added in the Python AI services phase.
