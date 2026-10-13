# Testing with Real Cloud Providers

This guide walks you through setting up free-tier cloud providers (OpenRouter, Groq, Google Gemini) and testing the SIP AI Platform end-to-end.

## Prerequisites

- Linux/macOS environment
- Python 3.14+, Node 26.10.0+, Elixir 1.18+ (all installed)
- API keys from free providers

## Step 1: Get Free API Keys

### Option A: OpenRouter (Recommended - Many free models, single key)
1. Go to [openrouter.ai](https://www.openrouter.ai/)
2. Sign up (email, no credit card required for free models)
3. Get your API key from [openrouter.ai/keys](https://www.openrouter.ai/keys)
4. Free tier: 50 requests/day (1000/day with $10 top-up); many free models available

**Recommended free LLM models:** `openai/gpt-oss-20b:free`, `qwen/qwen3-14b:free`, `google/gemma-4-26b-a4b-it:free`

**Recommended free STT:** `openai/whisper-large-v3-turbo`

### Option B: Groq (Fastest, great for real-time)
1. Go to [console.groq.com](https://console.groq.com/)
2. Sign up (no credit card)
3. Get API key from [console.groq.com/keys](https://console.groq.com/keys)
4. Free tier: 1000 requests/day (varies by model)

**Models:** LLM `llama-3.3-70b-versatile`, STT `whisper-large-v3-turbo`, TTS `openai/tts-1`

### Option C: Google Gemini (AI Studio)
1. Go to [aistudio.google.com](https://aistudio.google.com/)
2. Sign in with Google
3. Get API key from [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
4. Free tier available (rate-limited)

**Models:** LLM `gemini-2.5-flash-lite`, STT `gemini-2.5-flash`

## Step 2: Configure Environment

Copy the unified config and add your keys:

```bash
cd /home/projects/sip-ai-platform
cp setup.env.example .env
```

Edit `.env` (or set per-service). For example with OpenRouter:

```bash
# LLM
LLM_PROVIDER=openrouter
LLM_MODEL=qwen/qwen3-14b:free
OPENROUTER_API_KEY=sk-or-v1-your-key-here

# STT
STT_PROVIDER=openrouter
STT_OPENROUTER_MODEL=openai/whisper-large-v3-turbo

# TTS (optional)
TTS_PROVIDER=openrouter
TTS_OPENROUTER_MODEL=openai/tts-1
TTS_OPENROUTER_VOICE=alloy
```

Or with Groq:

```bash
LLM_PROVIDER=groq
LLM_MODEL=llama-3.3-70b-versatile
GROQ_API_KEY=gsk_your-key-here
STT_PROVIDER=groq
TTS_PROVIDER=groq
```

## Step 3: Start Services

You need to start all 4 Python services + Control API.

**Important**: Python services require `PYTHONPATH=src` since modules are in `src/`.

### Quick Start (All Services)
```bash
bash services/start_all.sh
```

### Manual Start

### Terminal 1: STT (port 5001)
```bash
cd /home/projects/sip-ai-platform/services/stt
PYTHONPATH=src python3 -m stt.server
```

Or use helper: `./run.sh`

### Terminal 2: LLM (port 5002)
```bash
cd /home/projects/sip-ai-platform/services/llm
PYTHONPATH=src python3 -m llm.server
```

### Terminal 3: TTS (port 5003)
```bash
cd /home/projects/sip-ai-platform/services/tts
PYTHONPATH=src python3 -m tts.server
```

### Terminal 4: VAD (port 5004)
```bash
cd /home/projects/sip-ai-platform/services/vad
PYTHONPATH=src python3 -m vad.server
```

### Terminal 5: Control API (port 4001)
```bash
CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1 CALL_BACKEND=simulated node apps/control_api/dist/server.js
```

All services start in mock by default. With env vars set, they use real providers.

## Step 4: Verify Services

Check health endpoints:

```bash
curl http://127.0.0.1:5001/health  # STT
curl http://127.0.0.1:5002/health  # LLM
curl http://127.0.0.1:5003/health  # TTS
curl http://127.0.0.1:5004/health  # VAD
curl http://127.0.0.1:4001/healthz  # Control API
```

Quick provider test:

```bash
python3 /home/projects/sip-ai-platform/scripts/test-cloud-providers.py
```

Test LLM directly:

```bash
curl -X POST http://127.0.0.1:5002/v1/generate \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello in 3 words"}]}'
```

Test STT (send minimal PCM - mock style works too; real audio needs proper format):

```bash
curl -X POST http://127.0.0.1:5001/v1/transcribe \
  -H "Content-Type: application/json" \
  -d '{"audio":"dGVzdA=="}'
```

## Step 5: Test via Control API (real ARI call)

With `CALL_BACKEND=ari` the Control API drives Asterisk. `to` may be a bare
extension (`2000`) or a full endpoint (`Local/2000@internal`, `PJSIP/1001`).

```bash
curl -X POST http://127.0.0.1:4001/api/v1/calls \
  -H "Content-Type: application/json" \
  -d '{"to":"+15551234567","from":"+15550000000","context":{"purpose":"test"}}'
```

Response includes call_id. Check events:

```bash
curl "http://127.0.0.1:4001/api/v1/calls/{CALL_ID}/events?since=0&wait=1000"
```

Speak to call:

```bash
curl -X POST http://127.0.0.1:4001/api/v1/calls/{CALL_ID}/speak \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello, how can I help?"}'
```

Hangup:

```bash
curl -X POST http://127.0.0.1:4001/api/v1/calls/{CALL_ID}/hangup
```

## Step 6: Test via Telephony MCP (Brain Integration)

The MCP server connects to Control API and exposes tools to OpenCode/other brains.

### Build MCP server
```bash
cd apps/telephony_mcp && npx tsc --outDir dist
```

### Test demo
```bash
node apps/telephony_mcp/scripts/demo-voice-loop.mjs
```

This validates full brain-side loop with simulated backend.

### Plug into OpenCode

See [OPENCODE-INTEGRATION.md](./OPENCODE-INTEGRATION.md) for complete OpenCode integration instructions. 

Quick config:
```json
{
  "mcpServers": {
    "telephony": {
      "command": "node",
      "args": ["/home/projects/sip-ai-platform/apps/telephony_mcp/dist/server.js"],
      "env": {
        "CONTROL_API_BASE_URL": "http://127.0.0.1:4001"
      }
    }
  }
}
```

## Step 7: Real-Time Testing with Linphone

For actual SIP calls (requires Asterisk/ARI setup):

1. Install Linphone ([linphone.org](https://www.linphone.org/))
2. Configure SIP account pointing to your Asterisk server
3. Start Control API with ARI backend:
```bash
CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1 CALL_BACKEND=ari \
ARI_BASE_URL=http://your-asterisk:8088 \
ARI_USERNAME=voice_core ARI_PASSWORD=your-pass ARI_APP=voice_core \
node apps/control_api/dist/server.js
```
4. Start call from Linphone to your SIP trunk/extension configured in Asterisk, or originate via API/MCP to Linphone's number
5. For full OpenCode integration, follow [OPENCODE-INTEGRATION.md](./OPENCODE-INTEGRATION.md)

Note: On this host, Asterisk may not be installed - simulated backend is sufficient for testing AI pipeline. The full OpenCode+MCP integration works perfectly in simulated mode.

## Troubleshooting

- **429/Rate limits**: Switch to different model or provider; free tiers have daily limits
- **Auth errors**: Check API key format and env vars are loaded
- **Connection refused**: Ensure all services running on correct ports
- **TTS returns wrong format**: Our implementation converts to 16-bit big-endian PCM as required
- **STT multipart issues**: For Groq, we send WAV-wrapped PCM; works with whisper models

## Tips

- Start with mock providers first to validate pipeline, then switch to cloud
- Use OpenRouter for trying multiple free models without multiple keys
- Groq is best for lowest latency (voice conversations)
- Monitor service logs for provider errors
- All changes maintain backward compatibility - mock still works
