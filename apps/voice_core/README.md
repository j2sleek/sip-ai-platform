# voice_core

**Runtime:** Elixir 1.20.2 / Erlang-OTP 29 · **Service name:** `voice_core`

## Purpose

The real-time core of the SIP AI Platform. Owns call lifecycle, concurrent
call sessions, supervision, process orchestration, and (in later phases)
Asterisk/ARI control, media coordination, agent orchestration, and tool
execution coordination.

**Phase 1 scope:** foundation only — a minimal supervised OTP application with
a health check and environment-driven configuration. No Asterisk, ARI, SIP,
RTP, AudioSocket, WebSocket media, AI, or HTTP server yet.

## How to run

```sh
export PATH="/opt/elixir/bin:$PATH"     # if not already on PATH
mix deps.get
mix run --no-halt                        # starts the supervision tree
```

## How to test

```sh
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

## Health

`VoiceCore.health/0` returns `:ok` when the supervision tree is alive.
`VoiceCore.health_report/0` returns the shared `HealthResponse` contract:

```elixir
%{status: "ok", service: "voice_core", version: "0.1.0"}
```

Quick check:

```sh
mix run -e 'IO.inspect(VoiceCore.health_report())'
```

## Configuration

Environment-driven via `config/runtime.exs`:

| Variable | Default | Meaning |
|---|---|---|
| `APP_ENV` | `development` | Application environment |
| `LOG_LEVEL` | `info` | `debug` \| `info` \| `warning` \| `error` |

See `.env.example`. No secrets are defined in this phase.

## Current limitations

- Supervision tree has no children yet (bootstrap only).
- No telephony, media, or AI integration.

## Future responsibilities

`CallSupervisor`, `CallSession`, `MediaSession`, `AgentSession`,
`ProviderSupervisor`, `ToolSupervisor` — added in later phases (see `PLAN.md`).
