# SIP AI Platform

A zero-cost, self-hosted AI voice platform. A [Linphone](https://www.linphone.org/)
user can call an AI agent, and the AI agent can call the user back — with
real-time speech-to-text, an LLM, and text-to-speech in the loop, all running on
local/free software first.

> **Status: Phase 0 ✅ · Phase 0.5 ✅ · Phase 1 ✅ · Phase 2A ✅ (Asterisk Discovery).**
> The full platform is **not** implemented yet. The repository now contains:
> - Multi-runtime foundation (Elixir `voice_core`, Node `control_api`, Python `stt`/`llm`/`tts`)
> - Shared contracts and test scripts
> - **Asterisk 22.5.2** installed and verified (PJSIP, ARI, AudioSocket available; chan_websocket not present)
> - Custom start/stop/status scripts for systemd-free environment
> - Comprehensive capability report in [`docs/ASTERISK-CAPABILITIES.md`](docs/ASTERISK-CAPABILITIES.md)
> 
> **Next milestone: Phase 2B — PJSIP Telephony Foundation.** See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md),
> [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md), [`docs/DECISIONS.md`](docs/DECISIONS.md) (ADR-0007, ADR-0008),
> [`docs/ASTERISK-CAPABILITIES.md`](docs/ASTERISK-CAPABILITIES.md), and [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md).
>
> **Toolchain:** Erlang/OTP 29 · Elixir 1.20.2 · Node.js 24.18.0 · Python 3.14.6.

## Architecture overview

```text
Linphone ──SIP/RTP──▶ Asterisk / PJSIP
                          │
                          │ ARI (control) + media transport
                          ▼
                   Elixir / OTP real-time core
                   ├─ call session supervision
                   ├─ media coordination (MediaTransport abstraction)
                   ├─ agent orchestration
                   └─ tool routing
                          │
             ┌────────────┴─────────────┐
             ▼                           ▼
   Python AI services         Node.js / TypeScript services
   ├─ STT (Whisper)           ├─ ChartCapture API
   ├─ LLM (Ollama)            └─ integrations
   └─ TTS (Piper)
             │
             ▼
     n8n · Supabase/PostgreSQL · external APIs
```

Full detail lives in the design docs at the repository root:
[`ARCHITECTURE.md`](ARCHITECTURE.md),
[`MEDIA-STREAMING-DECISION.md`](MEDIA-STREAMING-DECISION.md),
[`PLAN.md`](PLAN.md), [`AGENTS.md`](AGENTS.md),
[`TOOL-SPEC.md`](TOOL-SPEC.md), [`API-SPEC.md`](API-SPEC.md),
[`TESTING.md`](TESTING.md).

## Technology responsibilities

| Layer | Technology | Owns |
|---|---|---|
| Telephony | **Asterisk / PJSIP** | SIP registration, dial plan, call setup/teardown, RTP, DTMF. **No AI logic.** |
| Real-time core | **Elixir / OTP** | ARI call control, per-call supervised sessions, media coordination, agent + tool orchestration, Control API, observability. |
| AI inference | **Python** | STT, LLM adapters, TTS behind stable HTTP APIs. **No SIP state.** |
| Control / Integrations | **Node.js / TypeScript** | `control_api` (new, in this repo) plus TypeScript integrations. The existing `chartcapture-api` remains a separate, independent project and is **not** modified here. |
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
│   └── control_api/      # Node/TypeScript/Fastify control API  (service: control_api)
├── services/
│   ├── stt/              # Python speech-to-text service        (service: stt)
│   ├── llm/              # Python LLM adapter service           (service: llm)
│   └── tts/              # Python text-to-speech service        (service: tts)
├── packages/
│   └── contracts/        # Shared, versioned JSON-Schema contracts
├── infra/
│   ├── asterisk/         # Asterisk config templates (later phases, no secrets)
│   ├── docker/           # Container definitions (production target)
│   └── scripts/          # Infra provisioning helpers
├── docs/
│   ├── ENVIRONMENT.md    # Environment report
│   ├── DECISIONS.md      # Architecture Decision Records
│   ├── TOOLCHAIN.md      # Pinned toolchain + reproduction
│   └── DEVELOPMENT.md    # Development workflow
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
Each app/service also has its own `README.md`.

## Development phases

Implementation is strictly incremental (full detail in [`PLAN.md`](PLAN.md)).
**Never implement a future phase without explicit instruction.**

| Phase | Focus |
|---|---|
| **0** ✅ COMPLETE | Environment discovery, doctor, bootstrap structure, decision records |
| **0.5** ✅ COMPLETE | Elixir/OTP compatibility, toolchain pin, minimal `voice_core` OTP app |
| **1** ✅ COMPLETE | Repository foundation (Elixir/Python/Node build independently, health, contracts) |
| **2A** ✅ COMPLETE | Asterisk installation & capability discovery (22.5.2, PJSIP/ARI/AudioSocket verified) |
| **2B** ← next | Asterisk + Linphone (PJSIP endpoints 1001/2000, dial plan, two-way audio) |
| 2C | Linphone registration and call testing |
| 3 | Elixir ARI control (detect/answer/hangup/originate, call state) |
| 4 | Media transport POC (AudioSocket first, then WebSocket) |
| 5 | Python AI services (STT/LLM/TTS with `/health`) |
| 6 | Agent runtime |
| 7 | Barge-in (VAD, TTS cancellation) |
| 8 | Tool system (`run_n8n_workflow`, `capture_chart`, `get_market_data`) |
| 9 | Outbound calling (`POST /api/v1/calls`) |
| 10 | Observability |
| 11 | Security hardening |
| 12 | Load testing |
| 13 | Production deployment (Ubuntu VPS) |

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

**Python — stt / llm / tts** (standard library only, no installs):

```sh
cd services/stt        # or services/llm, services/tts
PYTHONPATH=src python3 -m unittest discover -s tests -v
PYTHONPATH=src python3 -m stt.server                 # GET /health on :5001
```

**Node — control_api**:

```sh
cd apps/control_api
npm install && npm run build && npm test
npm run dev                                          # GET /health on :4000
```

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

Asterisk 22.5.2 is installed from Ubuntu 26.04 apt. See [`docs/ASTERISK-CAPABILITIES.md`](docs/ASTERISK-CAPABILITIES.md) for verified capabilities and [`infra/asterisk/README.md`](infra/asterisk/README.md) for runtime management.

**Repo-wide:**

```sh
sh scripts/test-all.sh      # every runtime's tests; non-zero if any fail
sh scripts/health-all.sh    # probe /health of locally running services
```

Health standard: every service returns
`{ "status": "ok", "service": "<name>", "version": "<v>" }`
(contract in [`packages/contracts`](packages/contracts)). Toolchain setup and
reproduction steps are in [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md).

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
