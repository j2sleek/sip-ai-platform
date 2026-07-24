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
