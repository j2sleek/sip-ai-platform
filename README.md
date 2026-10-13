# SIP AI Platform

A zero-cost, self-hosted AI voice platform. A [Linphone](https://www.linphone.org/)
user can call an AI agent, and the AI agent can call the user back — with
real-time speech-to-text, an LLM, and text-to-speech in the loop, all running on
local/free software first.

> **Status: Phase 0 ✅ · 0.5 ✅ · 1 ✅ · 2A ✅ · 2B ✅ · **2C ✅ live** · 3 ✅ · 4 ✅ · 5 ✅ · 6 ✅ · 7 ◑ · 9 ✅ live · MCP brain ✅.**
> The platform runs **live end-to-end**: a real Linphone call over SIP/RTP into
> Asterisk, bridged to the Elixir core over AudioSocket, with real STT → LLM →
> TTS in the loop, and OpenCode able to read the live transcript and speak into
> the call via MCP. It also runs in **simulated** mode (no Asterisk required) for
> tests. The repository contains:
> - Multi-runtime foundation (Elixir `voice_core`, Node `control_api` +
>   `telephony_mcp`, Python `stt`/`llm`/`tts`/`vad`)
> - Elixir: per-call sessions, real AudioSocket media transport (host-endian
>   wire ↔ big-endian internal), real-time paced output with silence keepalive,
>   turn-taking/barge-in state machine, brain interface (static / HTTP-LLM)
> - Python AI services behind swappable providers (mock by default;
>   Groq / whisper.cpp / Ollama / Piper opt-in) — standard library only
> - Outbound call control (`POST /api/v1/calls`) with `simulated` and `ari`
>   backends
> - **OpenCode as the brain** via the `telephony_mcp` MCP server — see
>   [`docs/VOICE-MEETINGS.md`](docs/VOICE-MEETINGS.md)
> - Shared contracts and repo-wide test/health scripts
>
> **Not yet done on this host:** the tool system (Phase 8), streaming STT/TTS,
> and observability / security / load / deployment (Phases 10–13). See
> [`PLAN.md`](PLAN.md).
>
> **Toolchain (verified on this host):** Erlang/OTP 27 · Elixir 1.18.3 ·
> Node.js 26.10.0 · npm 11.19.1 · Python 3.14.4. Node apps pin TypeScript 7,
> Fastify 5.12, and MCP SDK 1.32 (see [`docs/DECISIONS.md`](docs/DECISIONS.md), ADR-0013).

## Architecture overview

```text
        OpenCode (brain) ──MCP/stdio──▶ telephony_mcp
                                            │ HTTP /api/v1
                                            ▼
Linphone ──SIP/RTP──▶ Asterisk / PJSIP   control_api  (call control + event log)
                          │                 │ backend: simulated | ari
                          │ ARI + media     │
                          ▼                 ▼
                   Elixir / OTP real-time core
                   ├─ call session supervision
                   ├─ media coordination (MediaTransport abstraction)
                   ├─ agent orchestration + turn-taking / barge-in
                   └─ tool routing
                          │
             ┌────────────┴─────────────┐
             ▼                           ▼
   Python AI services         Node.js / TypeScript services
   ├─ STT (Whisper)           ├─ control_api (outbound-call API)
   ├─ LLM (Ollama)            ├─ telephony_mcp (MCP server for the brain)
   ├─ TTS (Piper)             └─ ChartCapture API (separate project)
   └─ VAD (energy)
             │
             ▼
     n8n · Supabase/PostgreSQL · external APIs
```

Full detail lives in the design docs at the repository root:
[`ARCHITECTURE.md`](ARCHITECTURE.md),
[`MEDIA-STREAMING-DECISION.md`](MEDIA-STREAMING-DECISION.md),
[`PLAN.md`](PLAN.md), [`AGENTS.md`](AGENTS.md),
[`TOOL-SPEC.md`](TOOL-SPEC.md), [`API-SPEC.md`](API-SPEC.md),
[`TESTING.md`](TESTING.md). The voice-meeting vision is in
[`docs/VOICE-MEETINGS.md`](docs/VOICE-MEETINGS.md).

## Technology responsibilities

| Layer | Technology | Owns |
|---|---|---|
| Telephony | **Asterisk / PJSIP** | SIP registration, dial plan, call setup/teardown, RTP, DTMF. **No AI logic.** |
| Real-time core | **Elixir / OTP** | ARI call control, per-call supervised sessions, media coordination, agent + tool orchestration, Control API, observability. |
| AI inference | **Python** | STT, LLM adapters, TTS behind stable HTTP APIs. **No SIP state.** |
| Control / Integrations | **Node.js / TypeScript** | `control_api` (outbound-call API, call control + event log) and `telephony_mcp` (MCP stdio server exposing call control to the brain). The existing `chartcapture-api` remains a separate, independent project and is **not** modified here. |
| Brain | **OpenCode + MCP** | Conversational/reasoning "brain" driving voice via the `telephony_mcp` MCP server. Not in the real-time audio path. See [`docs/VOICE-MEETINGS.md`](docs/VOICE-MEETINGS.md). |
| Automation | **n8n** | Business workflows, external SaaS, notifications. Outside the real-time loop. |
| Persistence | **Supabase / PostgreSQL** | State where required. |

Media transport is chosen at runtime behind a `MediaTransport` abstraction. The
strategic target is Asterisk `chan_websocket`; the first implemented adapter is
AudioSocket, with RTP External Media as an interop fallback (see
[`docs/DECISIONS.md`](docs/DECISIONS.md), ADR-0003).

## Repository structure

```text
sip-ai-platform/
├── apps/
│   ├── voice_core/       # Elixir/OTP real-time core            (service: voice_core)
│   ├── control_api/      # Node/TypeScript/Fastify control API  (service: control_api)
│   └── telephony_mcp/    # Node MCP server for the brain        (service: telephony_mcp)
├── services/
│   ├── stt/              # Python speech-to-text service        (service: stt)
│   ├── llm/              # Python LLM adapter service           (service: llm)
│   ├── tts/              # Python text-to-speech service        (service: tts)
│   └── vad/              # Python voice-activity service        (service: vad)
├── packages/
│   └── contracts/        # Shared, versioned JSON-Schema contracts
├── infra/
│   ├── asterisk/         # Asterisk config templates (later phases, no secrets)
│   ├── docker/           # Container definitions (production target)
│   └── scripts/          # Infra provisioning helpers
├── docs/
│   ├── VOICE-MEETINGS.md      # OpenCode-as-brain vision + demo
│   ├── OPENCODE-INTEGRATION.md # OpenCode + MCP + Linphone integration
│   ├── TESTING-WITH-REAL-PROVIDERS.md # Testing with cloud providers
│   ├── ENVIRONMENT.md         # Environment report
│   ├── DECISIONS.md           # Architecture Decision Records
│   ├── TOOLCHAIN.md           # Pinned toolchain + reproduction
│   └── DEVELOPMENT.md         # Development workflow
├── scripts/
│   ├── doctor.sh         # Environment doctor (read-only diagnostics)
│   ├── test-all.sh       # Run all runtimes' test suites
│   └── health-all.sh     # Probe /health of running services
├── tests/
├── .env.example
├── .gitignore
└── README.md
```

The design documents and `AGENTS.md` currently live at the repository root.
Each app/service also has its own `README.md`. The end-to-end voice-loop demo is
`apps/telephony_mcp/scripts/demo-voice-loop.mjs`.

## Development phases

Implementation is strictly incremental (full detail in [`PLAN.md`](PLAN.md)).
**Never implement a future phase without explicit instruction.**

| Phase | Focus |
|---|---|
| **0** ✅ COMPLETE | Environment discovery, doctor, bootstrap structure, decision records |
| **0.5** ✅ COMPLETE | Elixir/OTP compatibility, toolchain pin, minimal `voice_core` OTP app |
| **1** ✅ COMPLETE | Repository foundation (Elixir/Python/Node build independently, health, contracts) |
| **2A** ✅ COMPLETE | Asterisk installation & capability discovery (22.5.2, PJSIP/ARI/AudioSocket verified) |
| **2B** ✅ COMPLETE | PJSIP configuration (endpoints 1001/2000, dialplan, RTP 10000-10100) |
| **2C** ✅ COMPLETE | SIP/RTP telephony validation — real Linphone call answered, audio verified both ways |
| **3** ✅ COMPLETE | Elixir ARI control (ARI connection + channel events; `voice_core`) |
| **4** ✅ COMPLETE | Media transport (AudioSocket adapter behind `MediaTransport`) |
| **5** ✅ COMPLETE | Python AI services (STT/LLM/TTS/VAD behind providers; `/health`) |
| **6** ✅ COMPLETE | Agent runtime (voice agent body + brain interface; brain/body split) |
| **7** ◑ PARTIAL | Barge-in works live (endpointing + turn state machine + barge-in cancel TTS); wire-level flush polish remains |
| 8 | Tool system (`run_n8n_workflow`, `capture_chart`, `get_market_data`) |
| **9** ✅ COMPLETE | Outbound calling (`POST /api/v1/calls`, `simulated` + `ari` backends, `telephony_mcp`); live ARI originate verified |
| **MCP brain** ✅ COMPLETE | OpenCode drives call control via `telephony_mcp` — see [`docs/VOICE-MEETINGS.md`](docs/VOICE-MEETINGS.md) |
| 10 | Observability |
| 11 | Security hardening |
| 12 | Load testing |
| 13 | Production deployment (Ubuntu VPS) |

✅ = implemented and tested · ◑ = partially implemented on this host (see Notes).

**Notes on partial phases**

- **Phase 7 (barge-in):** the endpointing + turn state machine and barge-in cancel
  the in-flight TTS playback and capture the interruption as the next utterance;
  flushing the last queued AudioSocket frame on cancel is the remaining polish.
- **Phase 9 (outbound):** the outbound-call API, `simulated` and `ari` backends,
  and the `telephony_mcp` MCP server are implemented and tested. A live ARI
  originate to a real Linphone endpoint has been verified end-to-end.
- **Phase 2C:** complete — a real Linphone call was answered and audio verified in
  both directions through Asterisk → AudioSocket → `voice_core`.

## Running the environment doctor

The doctor is a **read-only** diagnostic. It installs nothing, requires no root,
and only exits non-zero on a critical failure.

```sh
sh scripts/doctor.sh
```

It reports OS, architecture, CPU, RAM, disk, Termux/PRoot status, Docker,
systemd, and the versions of Elixir, Erlang, Mix, Node, npm, Python, pip,
Asterisk, and Git — plus Asterisk module availability when Asterisk is installed
and an **Elixir↔OTP compatibility check**.

## Running the services

Each runtime builds, tests, and runs independently. Full detail in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

**Elixir — voice_core** (toolchain at `/opt/elixir`, on `PATH`):

```sh
cd apps/voice_core
mix deps.get && mix compile --warnings-as-errors && mix test
mix run -e 'IO.inspect(VoiceCore.health_report())'   # => %{status: "ok", ...}
```

**Python — stt / llm / tts / vad** (standard library only, no installs):

```sh
cd services/stt        # or services/llm, services/tts, services/vad
PYTHONPATH=src python3 -m unittest discover -s tests -v
PYTHONPATH=src python3 -m stt.server                 # GET /health on :5001
```

Ports: `stt` :5001 · `llm` :5002 · `tts` :5003 · `vad` :5004.

**Node — control_api**:

```sh
cd apps/control_api
npm install && npm run build && npm test
npm run dev                                          # GET /health on :4000
```

**Node — telephony_mcp** (MCP stdio server for the brain):

```sh
cd apps/telephony_mcp
npm install && npm run build && npm test
CONTROL_API_URL=http://127.0.0.1:4000 node dist/server.js   # speaks MCP on stdio
```

**Voice-loop demo** (no Asterisk required — starts `control_api` in simulated mode
and drives `telephony_mcp` over real MCP stdio):

```sh
node apps/telephony_mcp/scripts/demo-voice-loop.mjs
```

See [`docs/VOICE-MEETINGS.md`](docs/VOICE-MEETINGS.md) for the full picture.

**Asterisk — telephony core**:

```sh
# Check status
cd infra/asterisk
./status.sh

# Start Asterisk (if not running)
./start.sh

# Stop Asterisk
./stop.sh

# Connect to CLI
asterisk -rx 'core show version'
asterisk -rx 'pjsip show endpoints'
```

Asterisk configuration lives under [`infra/asterisk/`](infra/asterisk/) (PJSIP
endpoints 1001/2000, dialplan, ARI/AudioSocket settings). The one-install script
`install_full.sh` installs Asterisk and renders the config via
`infra/asterisk/configure.sh`; `start_production.sh` then brings up the whole
stack and verifies ARI. See [`PRODUCTION.md`](PRODUCTION.md) for the full runbook,
[`docs/ASTERISK-CAPABILITIES.md`](docs/ASTERISK-CAPABILITIES.md) for verified
capabilities, and [`docs/LIVE-CALL-VERIFICATION.md`](docs/LIVE-CALL-VERIFICATION.md)
for the proven real-call path and AudioSocket protocol details.

**Production (one install + one start):**

```sh
./install_full.sh        # venvs, Node/Elixir builds, Asterisk install + config
export GROQ_API_KEY=gsk_...
./start_production.sh    # Asterisk + voice_core + control_api + AI services
```

**Repo-wide:**

```sh
sh scripts/test-all.sh      # every runtime's tests; non-zero if any fail
sh scripts/health-all.sh    # probe /health of locally running services
```

Health standard: every service returns
`{ "status": "ok", "service": "<name>", "version": "<v>" }`
(canonical names: `voice_core`, `control_api`, `telephony_mcp`, `stt`, `llm`,
`tts`, `vad`; contract in [`packages/contracts`](packages/contracts)). Toolchain
setup and reproduction steps are in [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md).

## Contributing with an AI coding agent

This repo is built to be extended by an AI coding agent under human supervision.
Before making changes, an agent must:

1. Read [`AGENTS.md`](AGENTS.md) — non-negotiable architecture rules.
2. Read the architecture docs relevant to the task.
3. Inspect the repository and installed versions (`sh scripts/doctor.sh`).
4. Identify the current milestone in [`PLAN.md`](PLAN.md).
5. **Implement only the requested phase.** No speculative abstractions, no
   future phases, no cloud dependencies where a local option is required.
6. Run formatter, static analysis, and tests.
7. Update documentation and report exact files changed and commands run.

Hard rules (see `AGENTS.md` for the full list): never put AI logic in Asterisk
dial plans; never put SIP logic in the agent; keep media behind `MediaTransport`
and STT/LLM/TTS behind provider interfaces; every call is an isolated session;
every external request has a timeout; **never hard-code or commit secrets**;
never assume Docker, systemd, or x86_64.

## Known environment constraints

This bootstrap host is **Ubuntu 26.04 (ARM64) under PRoot/Termux on Android**:
no Docker, `systemd` is not PID 1, no GPU/CUDA, and RAM is constrained. It is a
development/orchestration host — heavy AI inference is offloaded, and production
targets an Ubuntu VPS. See [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md).
