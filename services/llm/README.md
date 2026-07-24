# llm

**Runtime:** Python 3.14 · **Service name:** `llm`

## Purpose

LLM inference service. Generates assistant responses from conversation history.

**Phase 1 scope:** foundation only — a health endpoint and a provider interface
(`generate(messages) -> response`) with a placeholder implementation. **No real
LLM inference and no model downloads.**

## How to run

Zero-dependency (standard library only):

```sh
cd services/llm
PYTHONPATH=src python3 -m llm.server      # http://127.0.0.1:5002/health
```

Environment: `LLM_HOST` (default `127.0.0.1`), `LLM_PORT` (default `5002`).

## How to test

```sh
cd services/llm
PYTHONPATH=src python3 -m unittest discover -s tests -v
# or, if pytest is installed:  PYTHONPATH=src pytest
```

## Health

`GET /health` →

```json
{ "status": "ok", "service": "llm", "version": "0.1.0" }
```

## Current limitations

- `generate()` raises `NotImplementedError` (placeholder).
- No model loading and no external API calls.

## Future responsibilities

Local-first LLM (e.g. Ollama adapter, small quantized model) behind the
`LLMProvider` interface, added in the Python AI services phase.
