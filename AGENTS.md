# AGENTS.md — AI Coding Agent Instructions

## Mission

You are working on SIP AI Platform, a modular self-hosted AI voice system.

The project uses:

- Asterisk for telephony
- Elixir/OTP for real-time orchestration
- Python for AI inference
- Node.js/TypeScript for existing and integration services
- n8n for automation

## Non-Negotiable Architecture Rules

1. Never put AI business logic inside Asterisk dial plans.
2. Never put SIP signaling logic inside the AI agent.
3. Never make the agent depend directly on Asterisk internals.
4. Keep media transport behind a `MediaTransport` abstraction.
5. Keep STT, LLM and TTS behind provider interfaces.
6. Every call must have an isolated session.
7. Every external request must have a timeout.
8. Every process/resource must have cleanup logic.
9. Never hard-code secrets.
10. Never expose internal AI services publicly.
11. Do not rewrite working code unnecessarily.
12. Do not invent APIs. Verify installed versions and official documentation.
13. Do not silently swallow errors.
14. Do not use blocking work inside latency-sensitive Elixir processes.
15. Do not perform heavy AI inference inside the BEAM VM.
16. Use supervision trees for recoverable failures.
17. Use structured logs with call/session correlation IDs.

## Development Rules

Before coding:

- Inspect repository.
- Inspect OS and architecture.
- Inspect dependency versions.
- Read relevant docs.
- Identify the current milestone.

After coding:

- Run formatter.
- Run static analysis.
- Run unit tests.
- Run integration tests where available.
- Update documentation.
- Provide a concise implementation report.

## Change Discipline

Implement one milestone at a time.

Do not:

- Add speculative abstractions.
- Add unnecessary dependencies.
- Replace working components without evidence.
- Introduce cloud services when a local option is required.
- Assume Docker exists.
- Assume systemd exists.
- Assume x86_64.

## Repository Structure & Runtime Responsibilities (from Phase 1)

The repository is a loosely-coupled, multi-runtime foundation. Respect these
boundaries — do not blur them.

| Path | Runtime | Service name | Owns |
|---|---|---|---|
| `apps/voice_core` | Elixir/OTP | `voice_core` | Call state, sessions, supervision, orchestration; later ARI/media/agent/tools |
| `apps/control_api` | Node/TS/Fastify | `control_api` | HTTP control surface; later outbound-call API, webhooks, integrations |
| `services/stt` | Python | `stt` | Speech-to-text (provider: `transcribe(audio) -> text`) |
| `services/llm` | Python | `llm` | LLM inference (provider: `generate(messages) -> response`) |
| `services/tts` | Python | `tts` | Text-to-speech (provider: `synthesize(text) -> audio`) |
| `packages/contracts` | JSON Schema | — | Language-neutral cross-service data contracts |

Rules:

- STT/LLM/TTS stay behind their provider interfaces; media stays behind
  `MediaTransport`. Elixir calls Python/Node only via explicit APIs.
- Keep the runtimes independently buildable and testable.

## Naming Conventions

- Canonical service names — `voice_core`, `control_api`, `stt`, `llm`, `tts` —
  must be identical across READMEs, health endpoints, logs, env vars,
  documentation, and contracts.
- Correlation IDs: `call_id`, `session_id`, `tool_call_id` (see contracts).

## Testing Requirements

- After any change, run the affected runtime's tests; before finishing, run
  `sh scripts/test-all.sh` (must exit 0).
- Elixir: `mix compile --warnings-as-errors && mix test && mix format --check-formatted`.
- Python: `PYTHONPATH=src python3 -m unittest discover -s tests` (stdlib; pytest optional).
- Node: `npm run build && npm test`.
- Keep test suites lightweight; never embed real audio or secrets in tests.

## Configuration Rules

- All config is environment-driven with safe development defaults.
- Every service ships a `.env.example`; real `.env` files are git-ignored and
  never committed. No secrets in code, tests, or contracts.

## Foundation-Phase Guardrails

- Do **not** modify `/root/chartcapture-api` — it is a separate, independent project.
- Do **not** download or install large AI models during foundation development.
- Do **not** install or change Asterisk, or touch SIP/PJSIP/ARI/AudioSocket/
  `chan_websocket` before the phase that calls for it.
- Prefer small, incremental changes; run tests after modifications.
- Read this file and the relevant `docs/` before writing code.

## Failure Handling

Every failure must be classified:

- transient
- permanent
- configuration
- dependency
- user/call initiated
- programming error

Recoverable failures should be supervised or retried with bounded backoff.

Programming errors should be visible and observable.

## Security

Never commit:

- SIP passwords
- API keys
- tokens
- private keys
- database credentials

Use environment variables or secret management.

## Definition of Done

A feature is complete only when:

- implementation exists
- tests exist
- error paths are handled
- cleanup is implemented
- documentation is updated
- acceptance criteria pass
- known limitations are documented
