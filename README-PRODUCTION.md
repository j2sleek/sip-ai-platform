# Production Deployment

## One-Install
```bash
chmod +x install_full.sh
./install_full.sh
```

## Start (Full Production with Asterisk ARI)
```bash
export GROQ_API_KEY=gsk_your_groq_key
export ARI_PASSWORD=your_asterisk_ari_password
chmod +x start_production.sh
./start_production.sh
```

## Requirements
- Asterisk installed with ARI enabled (res_ari.so)
- ari.conf configured with username 'voice_core' matching ARI_PASSWORD
- GROQ_API_KEY for production LLM/STT/TTS
- Python 3.10+, Node 26+

## MCP Integration with OpenCode
MCP config at `opencode-mcp-config.json`:
```json
{
  "mcpServers": {
    "telephony": {
      "command": "node",
      "args": ["/home/projects/sip-ai-platform/apps/telephony_mcp/dist/server.js"],
      "env": { "CONTROL_API_BASE_URL": "http://127.0.0.1:4001" }
    }
  }
}
```
