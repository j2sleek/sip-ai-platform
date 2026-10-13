# contracts

Language-neutral, versioned data contracts shared across the SIP AI Platform
runtimes (Elixir `voice_core`, Node `control_api` and `telephony_mcp`, Python
`stt`/`llm`/`tts`/`vad`).

**Phase 1 goal:** document the data model. These schemas are the source of truth
for cross-service shapes; they are intentionally not yet wired into a code
generator or runtime validator (that is deliberate — no over-engineering).

Format: **JSON Schema (draft 2020-12)**, one file per contract under
[`schemas/`](schemas/). Version is carried in each `$id` (`/v1/`).

## Contracts

| Contract | File | Purpose |
|---|---|---|
| HealthResponse | `schemas/health_response.schema.json` | Standard health payload for every service |
| CallSession | `schemas/call_session.schema.json` | State of a single call (owned by `voice_core`) |
| CallIntent | `schemas/call_intent.schema.json` | Request to place an outbound call |
| CallEvent | `schemas/call_event.schema.json` | Call control/transcript event (owned by `control_api`) |
| Utterance | `schemas/utterance.schema.json` | One caller/agent turn in a transcript |
| VadAnalysis | `schemas/vad_analysis.schema.json` | VAD result from the `vad` service |
| AudioChunk | `schemas/audio_chunk.schema.json` | One chunk of call audio at the media boundary |
| Transcript | `schemas/transcript.schema.json` | STT output for a span of audio |
| AgentMessage | `schemas/agent_message.schema.json` | One message in agent conversation history |
| ToolRequest | `schemas/tool_request.schema.json` | Agent request to execute a tool |
| ToolResponse | `schemas/tool_response.schema.json` | Result of executing a tool |

## Health check standard

Every service — regardless of runtime — exposes health that conceptually returns:

```json
{
  "status": "ok",
  "service": "SERVICE_NAME",
  "version": "VERSION"
}
```

- `service` is one of the canonical names: `voice_core`, `control_api`,
  `telephony_mcp`, `stt`, `llm`, `tts`, `vad`.
- `status` is `ok` | `degraded` | `error`.
- HTTP services (`control_api`, `stt`, `llm`, `tts`, `vad`) expose it at
  `GET /health`.
- `voice_core` exposes it in-process via `VoiceCore.health_report/0`; the
  `telephony_mcp` server is stdio (no health endpoint).

## Canonical identifiers

- `call_id` — stable correlation ID for a call, present on every call-scoped
  contract and in structured logs across all services.
- `session_id` — the agent/media session bound to a call.
- `tool_call_id` — links a `ToolRequest` to its `ToolResponse`.

## Notes

- Audio is **never** embedded as real data in tests (`AudioChunk.data` is a
  base64 placeholder shape only).
- Contracts contain **no secrets**; `ToolRequest.arguments` never carries
  credentials (see `TOOL-SPEC.md`).
- Backwards-incompatible changes bump the version segment in `$id`.

## HTTP surface (current)

| Service | Method & path | Body → Response |
|---|---|---|
| control_api | `POST /api/v1/calls` | `CallIntent` → `{ call }` |
| control_api | `GET /api/v1/calls` | → `{ calls }` |
| control_api | `GET /api/v1/calls/:id` | → `{ call }` (with events) |
| control_api | `POST /api/v1/calls/:id/speak` | `{ text }` → `{ call }` |
| control_api | `POST /api/v1/calls/:id/hangup` | → `{ call }` |
| control_api | `GET /api/v1/calls/:id/events` | `?since=&wait=` → `{ events, call, cursor }` |
| stt | `POST /v1/transcribe` | raw PCM → `{ text, provider, duration_ms }` |
| llm | `POST /v1/generate` | `{ messages }` / `{ prompt }` → `{ response, provider, model }` |
| tts | `POST /v1/synthesize` | `{ text }` → raw PCM (`audio/pcm`) |
| vad | `POST /v1/analyze` | raw PCM or `{ pcm }` → `VadAnalysis` |

`control_api` may be guarded by a bearer token (`CONTROL_API_TOKEN`).
