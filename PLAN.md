# SIP AI Platform — Implementation Plan

## Goal

Build a zero-cost, self-hosted AI voice platform that supports:

- Linphone → AI calls
- AI → Linphone calls
- Real-time voice conversation
- Local STT/LLM/TTS
- Tool calling
- n8n integration
- ChartCapture integration
- High concurrency
- Fault isolation
- Portable deployment

## Phase 0 — Environment Doctor

Deliver:

- `scripts/doctor.sh`
- `mix`/Elixir version check
- Erlang/OTP check
- Node.js check
- Python check
- Asterisk check
- architecture check
- memory/CPU report
- optional Docker detection

Acceptance:

- A single command reports all prerequisites.
- No assumptions about x86_64, systemd or Docker.
- Termux limitations are documented.

## Phase 1 — Repository Foundation

Create:

- Elixir umbrella or well-structured OTP application
- Python services directory
- Node.js services directory
- infrastructure directory
- documentation
- CI checks

Deliver:

```text
apps/
services/
packages/
infra/
docs/
```

Acceptance:

- All projects build independently.
- Health checks exist.
- Configuration is environment-driven.

## Phase 2 — Asterisk + Linphone

Build:

- PJSIP endpoint 1001
- AI endpoint 2000
- secure credentials
- basic dial plan

Acceptance:

- Linphone registers.
- Linphone can call another SIP endpoint.
- Audio works in both directions.
- Calls terminate cleanly.

## Phase 3 — Elixir ARI Control

Implement:

- ARI HTTP client
- ARI WebSocket event client
- Stasis application
- call registry
- call state machine

Acceptance:

- Elixir detects inbound calls.
- Elixir can answer calls.
- Elixir can hang up calls.
- Elixir can originate calls.
- Call state is tracked reliably.

## Phase 4 — Media Transport POC

Implement first:

- WebSocket media adapter if compatible with baseline Asterisk.

Fallback:

- AudioSocket adapter.

Do not implement RTP first unless required.

Acceptance:

- Bidirectional audio is received.
- Audio can be returned.
- No audio leaks between calls.
- Call cleanup closes all media resources.
- Latency is measured.

## Phase 5 — Python AI Services

Create independent services:

```text
services/stt
services/llm
services/tts
```

Each exposes:

- `/health`
- version information
- structured errors
- request timeout handling

Initial implementations:

- Whisper-based STT
- Ollama LLM adapter
- Piper TTS

Acceptance:

- Each service can run independently.
- Elixir can call each service.
- Provider implementations can be swapped.

## Phase 6 — Agent Runtime

Implement in Elixir:

- conversation state
- agent session
- message history
- tool calls
- cancellation
- timeouts
- provider abstraction

Acceptance:

```text
User voice
  -> STT
  -> Agent
  -> LLM
  -> TTS
  -> User voice
```

## Phase 7 — Barge-in

Implement:

- VAD
- speech interruption detection
- TTS cancellation
- agent cancellation
- state recovery

Acceptance:

- User can interrupt AI.
- AI stops speaking quickly.
- New user utterance is processed.
- No stale TTS continues after interruption.

## Phase 8 — Tool System

Implement a standard tool contract.

Initial tools:

- `run_n8n_workflow`
- `capture_chart`
- `get_market_data`

Acceptance:

- Agent can call tools.
- Tool timeout is handled.
- Tool failure is converted into safe agent context.
- Tool credentials never enter prompts.

## Phase 9 — Outbound Calling

Implement:

```http
POST /api/v1/calls
```

Flow:

```text
API
 -> Elixir CallManager
 -> Asterisk
 -> Linphone rings
 -> answer
 -> attach media
 -> start agent session
```

Acceptance:

- AI can call Linphone.
- Context is passed into the agent.
- Call cleanup is deterministic.

## Phase 10 — Observability

Implement:

- structured logs
- call IDs
- session IDs
- latency metrics
- provider metrics
- tool metrics
- error counters
- health endpoints

Acceptance:

A single call can be traced across:

```text
Asterisk
Elixir
STT
LLM
Tool
TTS
```

## Phase 11 — Security

Implement:

- firewall rules
- SIP hardening
- strong credentials
- API authentication
- rate limits
- internal-only AI services
- secret management
- non-root execution

## Phase 12 — Load Testing

Test progressively:

- 1 call
- 5 calls
- 10 calls
- 25 calls
- target determined by hardware

Measure:

- CPU
- RAM
- call setup time
- STT latency
- LLM latency
- TTS latency
- end-to-end response time
- failure rate

## Phase 13 — Production Deployment

Target:

- Ubuntu VPS
- Elixir OTP release
- Asterisk
- Python services
- Node.js services
- PostgreSQL/Supabase
- n8n

Use:

- systemd or containers where supported
- Caddy for HTTPS
- firewall
- backups
- monitoring

## AI Coding Agent Workflow

For every phase:

1. Read `AGENTS.md`.
2. Read relevant architecture docs.
3. Inspect current repository.
4. Inspect installed versions.
5. Implement only the requested phase.
6. Run tests.
7. Run integration checks.
8. Fix failures.
9. Update docs.
10. Report exact files changed.
11. Report commands executed.
12. Report known limitations.
13. Commit the phase.

Never implement future phases without explicit instruction.

---

## Addendum — Brain/body split and the OpenCode MCP integration

The product direction (a live bidirectional voice meeting with an AI that can also
call you with build updates) led to a deliberate re-slice of Phases 6/7/9 that is
now implemented. The decision is recorded as **ADR-0010** in
[`docs/DECISIONS.md`](docs/DECISIONS.md); the vision and demo are in
[`docs/VOICE-MEETINGS.md`](docs/VOICE-MEETINGS.md).

**Brain/body split**

- **Brain** = OpenCode, extended with the `telephony_mcp` MCP server
  (`originate_call`, `speak`, `wait_for_input`, `hangup`, `get_transcript`, and a
  `call://{id}/transcript` resource). The brain decides *what* to say/do.
- **Body** = the platform's real-time runtimes: Asterisk (SIP/RTP), `voice_core`
  (per-call sessions, AudioSocket media, turn state, barge-in), and the Python
  `stt`/`llm`/`tts`/`vad` services. The body owns audio and latency.

**What was implemented**

| Area | Delivered |
|---|---|
| Phase 3 (ARI) | `voice_core` ARI connection + channel/turn wiring (config-gated) |
| Phase 4 (media) | AudioSocket adapter behind `MediaTransport`; event-driven server |
| Phase 5 (AI svcs) | `stt`/`llm`/`tts`/`vad` HTTP services, stdlib-only, provider interfaces (mock default; whisper.cpp/Ollama/Piper opt-in) |
| Phase 6 (agent) | `VoiceCore.VoiceAgent` (body) + `VoiceCore.Brain` interface (`Static`, `HTTPLLM`, `External`) with `respond/3`; per-turn sequencing, safe timer cancellation, bounded replies (ADR-0015); OpenCode-external brain mode (ADR-0016) |
| Phase 7 (barge-in) | Endpointing + turn state machine + barge-in detection in `VoiceAgent.Turn` (TTS-cancel wiring is the remaining piece) |
| Phase 9 (outbound) | `control_api` outbound-call API with `simulated` + `ari` backends; per-call event log + long-poll |
| MCP brain | `telephony_mcp` MCP stdio server + `demo-voice-loop.mjs` end-to-end demo |

**Verification without Asterisk**

The entire brain-side loop is exercised by real MCP stdio + HTTP with a simulated
call backend:

```sh
node apps/telephony_mcp/scripts/demo-voice-loop.mjs
```

**Live-call reliability fixes (follow-up)**

- ADR-0015: fixed a `VoiceAgent` timer-state corruption that crashed the agent
  (and ended the call) on barge-in/terminate; added per-turn sequencing so
  superseded turns can't speak late or out of order; bounded spoken reply length
  (`AGENT_MAX_REPLY_CHARS`, lower `LLM_MAX_TOKENS`) to stop per-turn latency
  growing with reply size.
- ADR-0016: added `VOICE_BRAIN=external` so OpenCode (via the telephony MCP
  tools) can be the sole brain answering a call.

**Still open**

- Phase 2C (Linphone/audio validation) and live Asterisk media E2E.
- Phase 8 (tool system): `run_n8n_workflow`, `capture_chart`, `get_market_data`.
- Streaming STT/TTS for lower latency; μ-law/A-law and resampling.
- Phases 10–13 (observability, security, load, deployment).
- **Stable SIP address**: the host's LAN IP is dynamic (it moved from
  `10.214.100.129` to `10.194.241.248`), so a softphone silently loses
  registration whenever it changes. Pin a stable address (static DHCP lease /
  fixed tethering subnet, or a resolvable hostname / mDNS name) and point
  Linphone's proxy at that, or have `control_api`/docs advertise the current SIP
  server address. Affects `LINPHONE_SETUP.md`, PJSIP transport bind, and any
  future multi-client deployments.
