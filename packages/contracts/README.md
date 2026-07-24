# contracts

Language-neutral, versioned data contracts shared across the SIP AI Platform
runtimes (Elixir `voice_core`, Node `control_api`, Python `stt`/`llm`/`tts`).

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

- `service` is one of the canonical names: `voice_core`, `control_api`, `stt`,
  `llm`, `tts`.
- `status` is `ok` | `degraded` | `error`.
- HTTP services (`control_api`, `stt`, `llm`, `tts`) expose it at `GET /health`.
- `voice_core` exposes it in-process via `VoiceCore.health_report/0` (no HTTP
  server in Phase 1).

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
