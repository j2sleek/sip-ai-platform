# control_api

**Runtime:** Node.js 24 / TypeScript / Fastify · **Service name:** `control_api`

## Purpose

The Control API for the SIP AI Platform. Owns the HTTP control surface and (in
later phases) integration orchestration, webhooks, and coordination with n8n and
the existing ChartCapture API.

**Phase 1 scope:** foundation only — a Fastify server with a `/health` endpoint
and environment-driven configuration. No outbound-call API, no integrations yet.

> This is a **new, independent** service. It does **not** use or modify
> `/root/chartcapture-api`.

## How to run

```sh
cd apps/control_api
npm install
npm run dev        # tsx watch (development)
# or
npm run build && npm start   # compiled (dist/server.js)
```

Server listens on `http://$HOST:$PORT` (default `0.0.0.0:4000`).

## How to test

```sh
npm run build      # TypeScript compilation
npm test           # node --test via tsx (Fastify inject, no port bound)
```

## Health

`GET /health` →

```json
{ "status": "ok", "service": "control_api", "version": "0.1.0" }
```

## Configuration

Environment-driven (`src/config.ts`):

| Variable | Default | Meaning |
|---|---|---|
| `APP_ENV` | `development` | Application environment |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `4000` | Bind port |
| `LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |

See `.env.example`. No secrets in this phase.

## Current limitations

- Only `/health` is implemented.
- No authentication, rate limiting, or integrations yet.

## Future responsibilities

Outbound call API (`POST /api/v1/calls`), call queries, hangup, webhooks, and
integration orchestration — added in later phases (see `API-SPEC.md`, `PLAN.md`).
