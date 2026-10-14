# control_api

**Runtime:** Node.js 26 / TypeScript 7 / Fastify 5 · **Service name:** `control_api`

## Purpose

The Control API for the SIP AI Platform. It owns the HTTP control surface — the
**outbound-call API** and the call control state / event log — and is the surface
the `telephony_mcp` MCP server drives on behalf of the AI brain.

Call **media/session** state remains owned by `voice_core`; events correlate by
`call_id`.

> This is a **new, independent** service. It does **not** use or modify
> `/root/chartcapture-api`.

## Call backends

Selected with `CALL_BACKEND`:

- **`simulated`** (default) — a fully in-memory call with a realistic event
  sequence and canned caller utterances. Lets the whole brain-side loop run with
  no telephony stack. Used by tests and the demo.
- **`ari`** — originates/hangs up channels via **Asterisk ARI**
  (`POST /ari/channels`, `DELETE /ari/channels/{id}`). Media/TTS remain owned by
  `voice_core`; `speak` records the agent utterance and delegates playback.

## API

| Method & path | Body | Response |
|---|---|---|
| `POST /api/v1/calls` | `{ to, from?, greeting? }` | `201 { call }` |
| `GET /api/v1/calls` | — | `{ calls }` |
| `GET /api/v1/calls/:id` | — | `{ call }` (with `events`) |
| `POST /api/v1/calls/:id/speak` | `{ text }` | `202 { call }` |
| `POST /api/v1/calls/:id/hangup` | — | `200 { call }` |
| `GET /api/v1/calls/:id/events` | `?since=<seq>&wait=<ms>` | `{ events, call, cursor }` |
| `POST /api/v1/calls/:id/events` | `{ type, data }` (voice_core ingest) | `202 { event }` |

`GET .../events` long-polls: it returns immediately if events after `since`
already exist, otherwise waits up to `wait` ms (capped by `MAX_EVENT_WAIT_MS`).

`POST .../events` is how the media body (`voice_core`) reports progress. If the
`id` is unknown, the call is registered as **inbound** (`direction: "inbound"`)
with the body's `channel_id` — a dial-in that entered the Stasis app — so the
brain bridge attaches and OpenCode/MCP can drive it like an originated call
(ADR-0018). Unknown event *types* are rejected with `400` and register nothing.

Event types: `call.created`, `call.ringing`, `call.answered`, `call.ended`,
`call.failed`, `utterance.user`, `utterance.agent`, `dtmf`
(see `packages/contracts` — CallEvent, Utterance).

### Examples

```sh
# place a call
curl -sS -X POST localhost:4000/api/v1/calls \
  -H 'Content-Type: application/json' \
  -d '{"to":"1000","greeting":"Hi, this is your build assistant."}'

# read new events (long-poll)
curl -sS 'localhost:4000/api/v1/calls/<id>/events?since=0&wait=5000'

# have the agent speak, then hang up
curl -sS -X POST localhost:4000/api/v1/calls/<id>/speak \
  -H 'Content-Type: application/json' -d '{"text":"Please hold."}'
curl -sS -X POST localhost:4000/api/v1/calls/<id>/hangup
```

## Health

`GET /health` →

```json
{ "status": "ok", "service": "control_api", "version": "0.2.0" }
```

## How to run

```sh
cd apps/control_api
npm install
npm run dev                  # tsx watch (development)
# or
npm run build && npm start   # compiled (dist/server.js)
```

Server listens on `http://$HOST:$PORT` (default `0.0.0.0:4000`).

## How to test

```sh
npm run build      # TypeScript 7 compilation
npm test           # node --test via tsx (Fastify inject; simulated backend)
```

The suite covers the calls API, the ARI client/backend against a local stub ARI
server, auth, and config parsing — no Asterisk required.

## Configuration

Environment-driven (`src/config.ts`); see `.env.example`.

| Variable | Default | Meaning |
|---|---|---|
| `APP_ENV` | `development` | Application environment |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `4000` | Bind port |
| `LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `CONTROL_API_TOKEN` | *(empty)* | Optional bearer token guarding `/api/v1/*` |
| `CALL_BACKEND` | `simulated` | `simulated` \| `ari` |
| `ARI_BASE_URL` | `http://127.0.0.1:8088` | Asterisk ARI base URL (with or without `/ari`) |
| `ARI_USERNAME` / `ARI_PASSWORD` | `voice_core` / *(empty)* | ARI credentials |
| `ARI_APP` | `voice_core` | Stasis application |
| `ARI_ENDPOINT_TEMPLATE` | `PJSIP/{to}` | Originate endpoint template |
| `ARI_CALLER_ID` | `"AI Assistant" <2000>` | Caller ID presented on outbound calls when the request omits `from` |
| `MAX_EVENT_WAIT_MS` | `30000` | Long-poll upper bound |
| `MAX_EVENTS_PER_CALL` | `1000` | Retained events per call |

Never commit `.env` or real secrets (AGENTS.md).

## Current limitations

- `ari` backend requires a running Asterisk (not present on the dev host).
- Call state is **in-memory**; there is no persistence yet (restart clears calls).
- No rate limiting yet.

## Related

- `apps/telephony_mcp` — the MCP server that drives this API.
- `docs/VOICE-MEETINGS.md` — end-to-end vision.
- `packages/contracts` — CallIntent, CallEvent, Utterance.
