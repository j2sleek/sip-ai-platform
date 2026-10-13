# Voice Meetings — OpenCode as the conversational brain

This document describes the end-to-end vision the platform is being built
towards, the architecture that realizes it, and how to try the working parts
today.

## Vision

Hold a **live, real-time, bidirectional voice meeting** with an AI brain that is
also doing engineering work. The same brain that plans and discusses features
with you can **call you back** with progress updates ("the migration is
committed, tests are green"), and you can talk to it as naturally as a phone
call.

The brain is **OpenCode**. Voice is just one more input/output modality for it,
alongside the editor, terminal, and files. The heavy real-time audio work stays
in the dedicated telephony runtimes, so the brain is never in the latency-
critical audio path.

## Architecture

```
        ┌────────────────────────────┐
        │   OpenCode  (the brain)    │
        │  reasoning, tools, code    │
        └──────────────┬─────────────┘
                       │ MCP (stdio)
              ┌────────▼─────────┐
              │  telephony_mcp   │  tools: originate_call, speak,
              │  (Node, stdio)   │         wait_for_input, hangup,
              └────────┬─────────┘         get_transcript, resource
                       │ HTTP /api/v1
              ┌────────▼─────────┐
              │   control_api    │  call control + event log
              │  (Node, Fastify) │  backend: simulated | ari
              └───┬──────────┬───┘
        originate │          │ events/transcript
                  ▼          ▲
        ┌──────────────┐  ┌──┴─────────────────────────────┐
        │  Asterisk    │  │  voice_core (Elixir/OTP)       │
        │  SIP/RTP     │──▶  per-call session, media,      │
        │  ARI         │  │  turn-taking, barge-in         │
        └──────┬───────┘  └───┬───────────┬───────────┬────┘
               │ AudioSocket  │ HTTP      │ HTTP      │ HTTP
               ▼              ▼           ▼           ▼
        (media bridge)   ┌──────┐   ┌──────┐   ┌──────┐  ┌──────┐
                         │ stt  │   │ llm  │   │ tts  │  │ vad  │
                         └──────┘   └──────┘   └──────┘  └──────┘
```

Responsibilities (unchanged from `AGENTS.md`):

| Component | Owns | Never does |
|---|---|---|
| Asterisk | SIP/RTP, channel setup/teardown, ARI | AI business logic |
| `voice_core` | per-call sessions, media transport, turn state, barge-in | SIP signaling internals |
| `control_api` | outbound-call API, call control state + event log | media/AI inference |
| `telephony_mcp` | MCP surface for the brain (stateless adapter) | own call state |
| `stt`/`llm`/`tts`/`vad` | one inference concern each, behind providers | SIP state |

Correlation: every call is identified by a `call_id`, present in every event and
in structured logs across services.

## The two directions

- **Inbound (user calls the agent):** the user dials in; `voice_core` answers via
  the Stasis app, opens an AudioSocket media path, runs endpointing/VAD, and
  streams caller audio to `stt`, the transcript to the brain (via the MCP
  resource/tools), and the brain's replies through `tts` back to the caller.
- **Outbound (the agent calls the user):** the brain calls `originate_call`; the
  backend places the call (simulated or ARI); the greeting and subsequent turns
  flow exactly as above.

## Try it now (no Asterisk required)

The whole **brain-side loop** runs end-to-end with a simulated call backend:

```sh
# one-time build
(cd apps/control_api && npm install && npm run build)
(cd apps/telephony_mcp && npm install && npm run build)

# run the demo: this script acts as the brain, connects over real MCP stdio,
# starts control_api, and holds a short scripted conversation.
node apps/telephony_mcp/scripts/demo-voice-loop.mjs
```

Expected shape of the output:

```
Placed call <uuid> → 1000 (state=ringing)

Conversation:
  -------┼--------------------------------------------------
  CALLER │ Yes, that sounds good.
  AGENT  │ Great — I'll note that. Anything else you'd like me to change?
  CALLER │ Can you tell me more about that?
  AGENT  │ Understood. I'll open a task for it and keep you posted.
  ...
Transcript has 7 turns (via get_transcript).
Transcript resource call://<uuid>/transcript returned 7 turns.
Hung up call <uuid> (state=ended).
```

## Wire OpenCode to it

Register the MCP server (local, stdio) in OpenCode's config:

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

Start `control_api` (and the Python services + `voice_core` for the full
pipeline), then ask the brain to call you:

> "Call extension 1000 and tell me when the voice platform is ready."

The brain will invoke `originate_call`, `wait_for_input`, `speak`, and
`get_transcript` as needed.

## Running the full stack (with Asterisk)

The pieces not exercised by the simulator are the telephony and media paths:

1. Asterisk with the Stasis app + AudioSocket (see `docs/ASTERISK-CAPABILITIES.md`).
2. `voice_core` configured with ARI + AudioSocket settings.
3. `stt`/`llm`/`tts` running (mock providers work; real providers are opt-in).
4. `control_api` with `CALL_BACKEND=ari` and ARI credentials.

> The current development environment has **no Asterisk**, so live calls are not
> exercised here. This is a documented limitation (see below), not a design gap:
> the control plane, MCP surface, and provider services are all built and tested.

## Current limitations

- No Asterisk in the dev environment → live-call audio path is untested here.
- `wait_for_input` returns one caller utterance per call; the brain loops using
  the returned `cursor`.
- `speak` on the ARI backend records the agent turn but delegates TTS playback to
  `voice_core` (the media owner); the simulated backend speaks inline.
- STT/TTS are 16-bit PCM at a fixed rate; no resampling/μ-law yet.
- No STT/TTS streaming yet (whole-utterance synthesis); a latency follow-up.

## Related

- `docs/DECISIONS.md` — ADR-0010…0013 (brain/MCP, providers, backends, toolchain).
- `apps/telephony_mcp/README.md` — MCP tools + config.
- `apps/control_api/README.md` — call control API.
- `packages/contracts` — CallIntent / CallEvent / Utterance / VadAnalysis.
