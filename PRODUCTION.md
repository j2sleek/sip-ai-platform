# Production Setup

All services are configured for Groq API. Set your GROQ_API_KEY and run.

## Quick Start

```bash
export GROQ_API_KEY=gsk_your_groq_api_key_here
bash run_production.sh
```

## Manual Start

```bash
export GROQ_API_KEY=gsk_your_key
export LLM_PROVIDER=groq LLM_MODEL=llama-3.3-70b-versatile
export STT_PROVIDER=groq STT_GROQ_MODEL=whisper-large-v3-turbo
export TTS_PROVIDER=groq TTS_GROQ_MODEL=openai/tts-1 TTS_GROQ_VOICE=alloy
export CALLS_BACKEND=simulated CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1

# Python services
cd services/stt && PYTHONPATH=src python3 -m stt.server &
cd services/llm && PYTHONPATH=src python3 -m llm.server &
cd services/tts && PYTHONPATH=src python3 -m tts.server &
cd services/vad && PYTHONPATH=src python3 -m vad.server &

# Control API
node apps/control_api/dist/server.js &
```

## OpenCode Integration

Build MCP server and configure OpenCode:
```bash
cd apps/telephony_mcp && npx tsc --outDir dist
```

MCP config:
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

For real SIP with Linphone, set `CALLS_BACKEND=ari` and configure Asterisk ARI credentials.

## ARI Credentials
Set ARI_USERNAME/ARI_PASSWORD to match Asterisk's ari.conf. Defaults: username voice_core.
