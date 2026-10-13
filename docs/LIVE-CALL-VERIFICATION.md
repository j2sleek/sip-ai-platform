# Live Call Verification (real Asterisk)

This document records the **verified** end-to-end production call path: a real
SIP endpoint (Linphone) talking to the AI over Asterisk, AudioSocket, the Elixir
core, and real STT/LLM/TTS — plus the OpenCode brain reading the transcript and
speaking into the live call via MCP.

It also pins the non-obvious protocol facts (AudioSocket wire format, byte order,
the 2 s idle timeout) so future work does not have to re-derive them.

## Verified outcome

| Stage | Result |
|---|---|
| Linphone `1001` registers (UDP 5060, PJSIP) | ✅ |
| ARI originate → Asterisk → Linphone rings → answered | ✅ |
| Channel handed to `[ai]` dial plan (`AudioSocket`) | ✅ |
| AudioSocket connect + UUID handshake → `MediaSession` bind | ✅ |
| Greeting synthesized (Groq TTS) and streamed to caller | ✅ |
| Caller speech captured → VAD/endpointed → STT (Groq Whisper) | ✅ `"Hi, how are you doing?"` |
| LLM reply (Groq) → TTS → streamed back | ✅ `"I'm doing great, thanks for asking. How can I assist you today?"` |
| Barge-in (caller talks over the agent) | ✅ |
| Transcript published to `control_api` (`utterance.user`/`utterance.agent`) | ✅ |
| OpenCode reads the live transcript via MCP (`get_transcript`) | ✅ |
| OpenCode injects speech into the live call (`POST /calls/:id/speak`) | ✅ streamed to caller |

## Data path

```text
Linphone ──SIP/RTP──▶ Asterisk(PJSIP) ──AudioSocket(TCP 9019)──▶ voice_core.MediaSession
                                                                      │ raw PCM (8 kHz s16)
                                                                      ▼
                                                          VoiceAgent (VAD/endpoint/turns)
                                                          │  stt → brain → tts  (HTTP)
                                                          ▼
                                          services/stt · services/llm · services/tts
                                                          │
                          control_api ◀── control bus ────┘ (agent.speak / utterance.*)
                                ▲
                                │ HTTP /api/v1
                          telephony_mcp ──MCP/stdio──▶ OpenCode (brain)
```

The **body** (turn-taking, audio, endpointing) lives in `voice_core`; the
**brain** (what to say) is OpenCode over MCP. They meet on the control bus:
`agent.speak` flows brain → body, `utterance.user` / `utterance.agent` flow
body → control_api (and thus to `get_transcript`).

## AudioSocket protocol facts (Asterisk 22)

These were confirmed against the Asterisk 22 source (`res/res_audiosocket.c`,
`apps/app_audiosocket.c`) **and** a live connection on this aarch64 host:

- **Frame header is 3 bytes**: `kind(1 byte)` + `length(2 bytes, big-endian)`.
  (The old assumption of a 4-byte header was wrong.)
- **Kinds**: `0x00` hangup · `0x01` UUID · `0x03` DTMF · `0x10` audio · `0xff` error.
- **Handshake**: Asterisk's first message is `kind=0x01, length=0x0010` with the
  **16 raw UUID bytes** as payload (not a printable string). The server uses this
  UUID to route the connection to the call's `MediaSession`.
- **Audio payload byte order is host-endian signed linear** (`slin`): little-endian
  on this ARM64/x86_64 host. The core keeps PCM **big-endian** internally, so
  `MediaSession` swaps at the wire edge (`VoiceCore.PCM.swap16/1`); STT (which
  expects little-endian) is converted again before `AI.transcribe/2`.
- **2 s idle timeout**: `app_audiosocket.c` uses `ast_waitfor_nandfds` with a
  2000 ms timeout and aborts the link if **neither** the channel **nor** the
  socket has activity. It is not enough to answer; the server must keep feeding
  frames. See "Output pacing" below.

## Output pacing (why silence is required)

`MediaSession` runs a 20 ms output ticker once a connection is attached. Each tick
sends exactly one 20 ms frame (320 bytes @ 8 kHz s16 mono):

- PCM queued by the `VoiceAgent` is drained at real time;
- when the queue is empty (e.g. while TTS is still synthesizing) **digital silence**
  is sent.

This simultaneously (a) keeps the AudioSocket link alive across the 2 s idle
timeout and (b) gives smooth, evenly paced playback instead of one large burst per
100 ms chunk. `send_audio/2` is therefore a **non-blocking enqueue**; the ticker
owns the wire.

## Reproduce

### A. Synthetic self-test (no phone needed)

`Echo()` returns the agent's own audio, exercising the full loop in both
directions:

```bash
asterisk -rx "channel originate Local/2000@internal application Echo"
# watch: run/voice_core.log  → handshake → bind → speak → STT → reply → barge-in
asterisk -rx "channel request hangup all"
```

### B. Real Linphone call

1. Start everything (see [`../PRODUCTION.md`](../PRODUCTION.md)):

   ```bash
   export GROQ_API_KEY=gsk_...
   ./start_production.sh
   ```

2. Register Linphone against Asterisk (see [`../LINPHONE_SETUP.md`](../LINPHONE_SETUP.md)).

3. Originate through the API (or via the MCP `originate_call` tool):

   ```bash
   curl -s -X POST http://127.0.0.1:4001/api/v1/calls \
     -H 'content-type: application/json' \
     -d '{"to":"1001","greeting":"Hi, this is your AI assistant."}'
   ```

   Answer on Linphone and speak.

4. Read the transcript / inject speech:

   ```bash
   curl -s http://127.0.0.1:4001/api/v1/calls/<call_id>
   curl -s -X POST http://127.0.0.1:4001/api/v1/calls/<call_id>/speak \
     -H 'content-type: application/json' -d '{"text":"Injected live."}'
   ```

   From OpenCode, the same operations are the `get_transcript` and `speak`
   telephony MCP tools.

## Notes / limitations

- Outbound (ARI-originated) calls enter Stasis while **ringing**. `CallSession`
  defers handing the channel to AudioSocket until `ChannelStateChange` reports
  `Up`, otherwise `app_audiosocket` aborts with "Channel is not answered".
- Hangup is detected as the AudioSocket TCP close → `:media_disconnected` → the
  `CallSession` ends and cleans up children (no restart on a normal child exit).
- ARI event handling ignores unmodeled events (`ChannelVarset`, etc.) instead of
  crashing the event WebSocket.
- Streaming STT/TTS (partial results, lower latency) is still future work
  (Phase 7+); the current loop uses turn-based endpointing.
