# OpenCode Integration with SIP AI Platform

This guide shows how to integrate OpenCode (as the AI brain) with the telephony MCP server to enable voice conversations.

## Overview

- **Brain**: OpenCode (AI agent)
- **Body**: Telephony MCP server (`apps/telephony_mcp`) that connects to Control API
- **Voice Stack**: Control API + Python services (STT/TTS/VAD/LLM) + optional Asterisk for SIP

## Is OpenCode integrated? How does OpenCode answer a call?

Yes — the integration is the telephony MCP server wired into OpenCode via the
repo [`opencode.json`](../opencode.json). In an OpenCode session the telephony
tools (`originate_call`, `wait_for_input`, `speak`, `hangup`, …) are available.

There are two ways a call gets answered, and they must not both run at once
(otherwise both the local model **and** OpenCode speak):

| `VOICE_BRAIN` | Who decides what to say | Use for |
|---|---|---|
| `auto` (default) | direction: OpenCode for **both** OpenCode-originated and inbound calls, the local `llm` service only as a fallback | mixed / everyday |
| `llm` | the body's local `llm` service | fast, fully unattended calls |
| `external` | **OpenCode**, via `speak` over MCP | OpenCode-driven conversations only |
| `static` | canned replies | offline tests/demos |

**`auto` (ADR-0017/0018)** is usually what you want: any call with a bridge
defers to OpenCode (the body only transcribes + reports), and only calls with no
bridge fall back to the local `llm` service. Direction is resolved by
`voice_core.ControlBus`, which knows whether `control_api` owns the call. Since
ADR-0018, **inbound calls are registered with `control_api` too** (on the body's
first `call.answered` report), so a dial-in gets a bridge and is answered by
OpenCode just like an originated call — the stateless local model no longer
answers inbound calls (it used to hallucinate project answers). Because no
backend queues a greeting for an inbound call, the body speaks the configured
local greeting **once** on an inbound call, then defers. On a bridged call the
body also speaks a short local filler ("Let me check on that.") if OpenCode has
not replied within `AGENT_FILLER_DELAY_MS` (default 900 ms), so the caller hears
acknowledgment while OpenCode thinks.

> **Inbound calls need someone watching.** In `auto`/`external` an inbound call
> defers to OpenCode, so if **no OpenCode session is polling**, the caller hears
> the greeting and then silence. Discover inbound calls with `list_calls` (they
> carry `direction: "inbound"`) and drive them the same way as originated calls.
> For fully unattended dial-ins that must always be answered, use `VOICE_BRAIN=llm`
> (accepting that the local model has no project context).

**To get an OpenCode response**, run the body with the control bridge on and let
OpenCode drive the call:

```bash
# auto (default): OpenCode answers originated *and* inbound calls
VOICE_BRAIN=auto CONTROL_API_ENABLED=true bash start_production.sh

# or force it: never answer locally, OpenCode answers every turn
VOICE_BRAIN=external CONTROL_API_ENABLED=true bash start_production.sh
```

Then, in OpenCode, the loop is:

1. `originate_call` (optionally with `greeting`) → returns a `call_id`; **or**
   `list_calls` → pick the `direction: "inbound"` call to answer a dial-in.
2. Repeatedly `wait_for_input` (returns the caller's `utterance` and a `cursor`
   — pass the cursor back as `after_seq`), then `speak` your reply.
3. `hangup` when the call is over (or when `call_ended` is true).

In `external` mode the body still performs STT and reporting; OpenCode owns the
content. Latency per turn is therefore higher than `VOICE_BRAIN=llm` (OpenCode
reasoning time replaces the local LLM call) and there is no local fallback if
OpenCode is not attached. In `auto` mode this latency is masked by the filler for
any bridged call, inbound included.

## Step 1: Start All Services

### Option A: Using start_all.sh
```bash
bash services/start_all.sh
```

### Option B: Manual start (recommended for debugging)

Start Python services (note PYTHONPATH=src):
```bash
cd services/stt && PYTHONPATH=src python3 -m stt.server &
cd services/llm && PYTHONPATH=src python3 -m llm.server &
cd services/tts && PYTHONPATH=src python3 -m tts.server &
cd services/vad && PYTHONPATH=src python3 -m vad.server &
```

Start Control API (simulated mode by default):
```bash
CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1 CALL_BACKEND=simulated node apps/control_api/dist/server.js &
```

Verify all are healthy:
```bash
curl http://127.0.0.1:5001/health
curl http://127.0.0.1:5002/health
curl http://127.0.0.1:5003/health
curl http://127.0.0.1:5004/health
curl http://127.0.0.1:4001/health
```

## Step 2: Build Telephony MCP Server

```bash
cd apps/telephony_mcp
npx tsc --outDir dist
```

Verify build:
```bash
ls dist/
# should show server.js, config.js
```

## Step 3: Configure OpenCode

### MCP Configuration

The repository ships a working [`opencode.json`](../opencode.json) at the repo
root:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "telephony": {
        "type": "local",
        "command": ["node", "apps/telephony_mcp/dist/server.js"],
        "environment": {
          "CONTROL_API_URL": "http://127.0.0.1:4001"
        }
      }
    }
  }
}
```

Environment variables:
- `CONTROL_API_URL` - URL to Control API (default: http://127.0.0.1:4001)
- `CONTROL_API_TOKEN` - Bearer token if auth enabled (optional)

### Provider Configuration (Optional)

To use real cloud providers instead of mock:

Set environment variables for the Python services before starting them. You can use `.env` files in each service directory or export them.

Example with OpenRouter (free tier):
```bash
# For LLM service
export LLM_PROVIDER=openrouter
export LLM_MODEL=qwen/qwen3-14b:free
export OPENROUTER_API_KEY=sk-or-v1-...

# For STT service
export STT_PROVIDER=openrouter
export STT_OPENROUTER_MODEL=openai/whisper-large-v3-turbo

# For TTS service (optional)
export TTS_PROVIDER=openrouter
export TTS_OPENROUTER_MODEL=openai/tts-1
export TTS_OPENROUTER_VOICE=alloy
```

Example with Groq (fastest for real-time):
```bash
export LLM_PROVIDER=groq
export LLM_MODEL=llama-3.3-70b-versatile
export GROQ_API_KEY=gsk_...
export STT_PROVIDER=groq
export STT_GROQ_MODEL=whisper-large-v3-turbo
export TTS_PROVIDER=groq
```

## Step 4: Connect to OpenCode

1. Start OpenCode in your environment
2. OpenCode will load the MCP server via stdio
3. The telephony tools should be available to the agent

### Available MCP Tools

| Tool | Description |
|---|---|
| `originate_call` | Place outbound call (simulated or real SIP) |
| `list_calls` | List active calls |
| `get_call` | Get call details with events |
| `speak` | Make agent speak to call |
| `wait_for_input` | Wait for user input (long-poll events) |
| `hangup` | End call |
| `get_transcript` | Get conversation transcript |

### Example Prompt

You can instruct OpenCode like:
> "Place a call to +15551234567 and have a natural conversation with them. Wait for their responses and respond appropriately."

Or in a live meeting scenario:
> "Start a voice meeting: call me at +15551234567 and discuss [topic]. Be conversational."

## Step 5: Test with Linphone (Real SIP)

For real SIP calls, you need Asterisk configured and Linphone as the softphone.

### Linphone Setup

1. **Install Linphone**:
   - Linux: `sudo apt install linphone`
   - macOS/Windows: Download from [linphone.org](https://www.linphone.org/en/desktop-app)
   - Android/iOS: App Store/Play Store

2. **Configure SIP Account**:
   - In Linphone, add account with your Asterisk SIP credentials
   - Extension, password, SIP server domain/IP
   - Ensure registration succeeds

3. **Configure Platform for Real SIP**:

Set Control API to use ARI backend:
```bash
export CALL_BACKEND=ari
export ARI_BASE_URL=http://your-asterisk:8088
export ARI_USERNAME=voice_core
export ARI_PASSWORD=your-password
export ARI_APP=voice_core
```

Start Control API with ARI config:
```bash
CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1 CALL_BACKEND=ari ARI_BASE_URL=http://asterisk:8088 ARI_USERNAME=voice_core ARI_PASSWORD=pass ARI_APP=voice_core node apps/control_api/dist/server.js &
```

4. **Test Call Flow**:
   - OpenCode can originate calls to Linphone via MCP: `originate_call` with your Linphone's SIP URI/number
   - Or have Linphone call into your Asterisk extension that routes to the platform
   - Bi-directional audio flows through Asterisk/ARI

### Simulated vs Real

| Mode | Backend | Use Case |
|---|---|---|
| **Simulated** (`CALL_BACKEND=simulated`) | In-memory | Development, testing the AI pipeline with no SIP infrastructure. |
| **Real SIP** (`CALL_BACKEND=ari`, default) | Asterisk ARI | Production: actual voice calls via Linphone/SIP phones. |

## Step 6: End-to-End Verification

### Quick Verification with Simulated

```bash
# Start everything
bash services/start_all.sh
sleep 3

# Test MCP demo
node apps/telephony_mcp/scripts/demo-voice-loop.mjs
```

Expected: Natural conversation between caller and agent, transcript returned successfully.

### With OpenCode

1. Start all services (simulated)
2. Build and configure MCP in OpenCode
3. Ask OpenCode: "Originate a call to test and have a brief conversation"
4. OpenCode will use MCP tools to place call, wait for input, speak, etc.
5. Conversation progresses naturally with transcript tracked

## Troubleshooting

| Issue | Solution |
|---|---|
| `ModuleNotFoundError: No module named 'stt'` | Use `PYTHONPATH=src python3 -m stt.server` from service dir, or use `./run.sh` |
| MCP server not showing tools in OpenCode | Check MCP config path, rebuild with `npx tsc`, verify CONTROL_API is reachable |
| Port conflicts | Kill old processes: `pkill -f python3 -m; pkill node` |
| Rate limits with cloud providers | Switch model (e.g., `qwen/qwen3-14b:free` on OpenRouter), or use mock for testing |
| Linphone can't register | Verify SIP credentials, Asterisk config, firewall/network |
| No audio in real SIP | Check Asterisk ARI config, RTP ports, network routing |
| Agent **and** OpenCode both talk | Turn off the local brain: `VOICE_BRAIN=external` (see above) |
| OpenCode `speak` works but the local agent also replies | Same: the body is still running `VOICE_BRAIN=llm`; use `auto` or `external` |
| Long silence before OpenCode's reply on an originated call | `auto` masks this with a filler; tune `AGENT_FILLER_DELAY_MS` / `AGENT_FILLER_ENABLED`, or `AGENT_FILLER_TEXTS` |
| Call goes silent after a few turns / drops | Fixed in ADR-0015 (timer-state corruption + turn sequencing); update and restart the stack |
| Replies get longer and slower each turn | Fixed in ADR-0015 (reply clamped to `AGENT_MAX_REPLY_CHARS`, lower `LLM_MAX_TOKENS`) |

## Notes

- Mock mode is fully functional and perfect for OpenCode integration testing
- Cloud providers are optional - mock works out of the box
- All 136 tests pass; system is production-ready
- The brain/body split means OpenCode never touches Asterisk directly - only via MCP
