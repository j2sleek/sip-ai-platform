# llm

**Runtime:** Python 3.14 (stdlib only) · **Service name:** `llm`

## Purpose

LLM inference service. Generates assistant responses from conversation history.

It exposes `POST /v1/generate` (chat messages in → assistant response out) behind
a swappable `LLMProvider` interface, plus `GET /health`. The default provider is
a dependency-free **mock**; a local **Ollama** adapter is selected with
`LLM_PROVIDER=ollama`.

The wire response is `{"response": "..."}` — the field the Elixir core parses
(`VoiceCore.Brain.HTTPLLM`).

## How to run

Zero-dependency (standard library only):

```sh
cd services/llm
PYTHONPATH=src python3 -m llm.server      # http://127.0.0.1:5002
```

Environment: `LLM_HOST` (default `127.0.0.1`), `LLM_PORT` (default `5002`),
`LLM_PROVIDER` (`mock` | `ollama`). See `.env.example` for all options.

## API

`POST /v1/generate`

```json
{ "messages": [ { "role": "user", "content": "book a meeting" } ] }
```

or `{ "prompt": "book a meeting" }` →

```json
{ "response": "...", "provider": "mock", "model": "mock-1" }
```

`GET /health` → `{ "status": "ok", "service": "llm", "version": "0.2.0" }`

Errors are structured: `{"error": {"code": "...", "message": "..."}}`.

## How to test

```sh
cd services/llm
PYTHONPATH=src python3 -m unittest discover -s tests -v
# or, if pytest is installed:  PYTHONPATH=src pytest
```

## Ollama

```sh
LLM_PROVIDER=ollama LLM_MODEL=llama3.2 OLLAMA_URL=http://127.0.0.1:11434 \
  PYTHONPATH=src python3 -m llm.server
```

## Cloud providers (outbound connection reuse)

The cloud providers (Groq / OpenRouter / Gemini) reuse keep-alive HTTP
connections for their outbound calls, so a burst of requests does not pay DNS +
TCP + TLS setup on every one. `HTTP_KEEPALIVE=0` disables this (fresh connection
per request); `HTTP_MAX_IDLE` (default `8`) bounds the idle connections kept per
provider host. See `docs/DECISIONS.md` ADR-0014.

## Current limitations

- No model weights are bundled or downloaded by this service.
- No streaming responses yet (single JSON reply); token streaming is a later
  milestone for lower latency.

## Related

- Contracts: `packages/contracts` (AgentMessage, HealthResponse).
- Caller: Elixir `VoiceCore.Brain.HTTPLLM`.
