# Development Workflow

How to work on the SIP AI Platform locally. This is the day-to-day companion to
[`README.md`](../README.md), [`TOOLCHAIN.md`](TOOLCHAIN.md), and
[`../AGENTS.md`](../AGENTS.md).

## Prerequisites

Run the environment doctor first:

```sh
sh scripts/doctor.sh
```

It must report no critical failures and `Compatibility: ... COMPATIBLE`. The
Elixir toolchain lives at `/opt/elixir` and is on `PATH` via
`/etc/profile.d/elixir.sh`.

## Repository layout

```text
apps/
  voice_core/    Elixir/OTP real-time core        (service: voice_core)
  control_api/   Node/TypeScript/Fastify control  (service: control_api)
services/
  stt/  llm/  tts/   Python AI services            (services: stt, llm, tts)
packages/
  contracts/     Language-neutral JSON Schema contracts
infra/           Asterisk/docker/scripts (later phases)
scripts/         doctor.sh, test-all.sh, health-all.sh
docs/            Environment, decisions, toolchain, this file
```

## Per-runtime workflow

### Elixir — voice_core

```sh
cd apps/voice_core
mix deps.get
mix compile --warnings-as-errors
mix test
mix format                 # apply formatting
mix format --check-formatted
mix run -e 'IO.inspect(VoiceCore.health_report())'
```

### Python — stt / llm / tts

Standard-library only in Phase 1 (no venv or installs required):

```sh
cd services/stt            # or services/llm, services/tts
PYTHONPATH=src python3 -m unittest discover -s tests -v
PYTHONPATH=src python3 -m stt.server        # GET /health on :5001 (llm :5002, tts :5003)
```

If you prefer pytest, it is optional and discovers the same tests:
`PYTHONPATH=src pytest`.

### Node — control_api

```sh
cd apps/control_api
npm install                # first time only
npm run dev                # tsx watch
npm run build              # tsc -> dist/
npm test                   # node --test via tsx
```

## Repo-wide commands

```sh
sh scripts/doctor.sh       # environment diagnostics (read-only)
sh scripts/test-all.sh     # run every runtime's tests; non-zero if any fail
sh scripts/health-all.sh   # probe /health of locally running services
```

## Configuration

All services are environment-driven with safe development defaults. Each has a
`.env.example`; copy to `.env` (git-ignored) and adjust. **Never commit `.env`
or secrets.**

| Service | Key vars |
|---|---|
| voice_core | `APP_ENV`, `LOG_LEVEL` |
| control_api | `APP_ENV`, `HOST`, `PORT`, `LOG_LEVEL` |
| stt / llm / tts | `STT_HOST`/`STT_PORT`, `LLM_HOST`/`LLM_PORT`, `TTS_HOST`/`TTS_PORT` |

## Health check standard

Every service returns `{ "status": "ok", "service": "<name>", "version": "<v>" }`.
HTTP services expose it at `GET /health`; `voice_core` via
`VoiceCore.health_report/0`. Contract: `packages/contracts/schemas/health_response.schema.json`.

## Contracts-first changes

When a cross-service shape changes, update the JSON Schema in
`packages/contracts/schemas/` first, then the implementations. Keep the
canonical service names (`voice_core`, `control_api`, `stt`, `llm`, `tts`) and
correlation IDs (`call_id`, `session_id`, `tool_call_id`) consistent everywhere.

## Guardrails (see AGENTS.md)

- Do **not** modify `/root/chartcapture-api`.
- Do **not** install Asterisk or touch SIP/PJSIP/ARI/media in foundation work.
- Do **not** download AI models.
- Prefer small, incremental changes; run tests after every change.
