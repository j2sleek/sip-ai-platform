# telephony_mcp

**Runtime:** Node 26 / TypeScript (ESM) · **Service name:** `telephony_mcp`

## Purpose

A Model Context Protocol (MCP) **stdio** server that exposes the platform's call
control to an AI brain — in this project, **OpenCode**. It makes voice one more
input/output modality for the brain: the brain can place a call, speak, wait for
what the caller says, and read the transcript, all through standard MCP tools.

It is a thin adapter over `control_api`; it owns no call state.

```
OpenCode (brain)
      │  MCP (stdio)
      ▼
telephony_mcp ──HTTP──▶ control_api ──▶ (simulated) | Asterisk ARI
                                              ▲
                                              │ media/agent
                                        voice_core (AudioSocket)
```

## Tools

| Tool | Args | Returns |
|---|---|---|
| `originate_call` | `to`, `from?`, `greeting?` | call summary (`id`, `state`, …) |
| `list_calls` | — | `{ calls: [...] }` |
| `get_call` | `call_id` | call status + transcript |
| `speak` | `call_id`, `text` | agent utterance accepted |
| `wait_for_input` | `call_id`, `after_seq?`, `timeout_ms?` | `{ utterance, cursor, timed_out, call_ended }` |
| `hangup` | `call_id` | call summary (`state: "ended"`) |
| `get_transcript` | `call_id` | `{ transcript: [{role,text,at}] }` |

## Resource

| URI | MIME | Contents |
|---|---|---|
| `call://{id}/transcript` | `application/json` | Caller/agent turns for a call |

## Configuration

Environment-driven (see `.env.example`): `CONTROL_API_URL` (default
`http://127.0.0.1:4000`), `CONTROL_API_TOKEN`, `REQUEST_TIMEOUT_MS`,
`DEFAULT_WAIT_MS`, `MAX_WAIT_MS`.

> **stdio note:** protocol messages travel on **stdout**; all logs go to
> **stderr**.

## Build & run

```sh
cd apps/telephony_mcp
npm install
npm run build
CONTROL_API_URL=http://127.0.0.1:4000 node dist/server.js   # speaks MCP on stdio
```

## Use with OpenCode

Register the server in your OpenCode MCP config (local, stdio). Example
`opencode.json` fragment:

```jsonc
{
  "mcp": {
    "telephony": {
      "type": "local",
      "command": ["node", "apps/telephony_mcp/dist/server.js"],
      "environment": { "CONTROL_API_URL": "http://127.0.0.1:4000" }
    }
  }
}
```

After registration, the brain can call e.g. `originate_call({ to: "1000",
greeting: "Hi, this is your build assistant." })` and then `wait_for_input`.

## How to test

```sh
cd apps/telephony_mcp
npm run build          # tsc (TypeScript 7)
npm test               # node --test with tsx; spins a stub control_api
```

The suite includes a full MCP end-to-end test (a real MCP `Client` talking to the
server over an in-memory transport) and exercises tool listing, tool calls, and
resource reads.

## Current limitations

- `wait_for_input` returns one caller utterance per call; the brain must loop
  (passing the returned `cursor` as `after_seq`).
- `speak` on the ARI backend records the agent utterance but delegates actual TTS
  playback to `voice_core` (media owner).
- No authentication on the stdio transport itself (it is a local process); the
  HTTP hop to `control_api` supports a bearer token.

## Related

- `apps/control_api` — the call control surface this server drives.
- `docs/VOICE-MEETINGS.md` — the end-to-end vision and demo.
- Contracts: `packages/contracts`.
