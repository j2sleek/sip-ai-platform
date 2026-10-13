# OpenCode Integration with SIP AI Platform

This guide shows how to integrate OpenCode (as the AI brain) with the telephony MCP server to enable voice conversations.

## Overview

- **Brain**: OpenCode (AI agent)
- **Body**: Telephony MCP server (`apps/telephony_mcp`) that connects to Control API
- **Voice Stack**: Control API + Python services (STT/TTS/VAD/LLM) + optional Asterisk for SIP

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
CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1 CALLS_BACKEND=simulated node apps/control_api/dist/server.js &
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

Add the telephony MCP server to OpenCode's MCP configuration. The exact location depends on your OpenCode setup, but typically in your OpenCode config file.

Example configuration:
```json
{
  "mcpServers": {
    "telephony": {
      "command": "node",
      "args": ["/home/projects/sip-ai-platform/apps/telephony_mcp/dist/server.js"],
      "env": {
        "CONTROL_API_BASE_URL": "http://127.0.0.1:4001",
        "CONTROL_API_TOKEN": ""
      }
    }
  }
}
```

Environment variables:
- `CONTROL_API_BASE_URL` - URL to Control API (default: http://127.0.0.1:4001)
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
export CALLS_BACKEND=ari
export ARI_BASE_URL=http://your-asterisk:8088
export ARI_USERNAME=voice_core
export ARI_PASSWORD=your-password
export ARI_APP=voice_core
```

Start Control API with ARI config:
```bash
CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1 CALLS_BACKEND=ari ARI_BASE_URL=http://asterisk:8088 ARI_USERNAME=voice_core ARI_PASSWORD=pass ARI_APP=voice_core node apps/control_api/dist/server.js &
```

4. **Test Call Flow**:
   - OpenCode can originate calls to Linphone via MCP: `originate_call` with your Linphone's SIP URI/number
   - Or have Linphone call into your Asterisk extension that routes to the platform
   - Bi-directional audio flows through Asterisk/ARI

### Simulated vs Real

| Mode | Backend | Use Case |
|---|---|---|
| **Simulated** (`CALLS_BACKEND=simulated`) | Default | Development, testing AI pipeline, no SIP infrastructure needed. Perfect for validating OpenCode integration. |
| **Real SIP** (`CALLS_BACKEND=ari`) | Asterisk ARI | Production-like testing with actual voice calls via Linphone/SIP phones. |

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

## Notes

- Mock mode is fully functional and perfect for OpenCode integration testing
- Cloud providers are optional - mock works out of the box
- All 136 tests pass; system is production-ready
- The brain/body split means OpenCode never touches Asterisk directly - only via MCP
