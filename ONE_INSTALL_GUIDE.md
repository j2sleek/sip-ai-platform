# One-Install Guide

## Install Everything
```bash
chmod +x install.sh start_all_venv.sh
./install.sh
```

## Start All Apps (Isolated Venvs)
```bash
export GROQ_API_KEY=gsk_your_key_here
./start_all_venv.sh
```

## Stop
```bash
pkill -f 'python3 -m'
pkill -f 'control_api/dist/server'
```

## Calling OpenCode from the App

Two approaches:
1. **OpenCode as Brain (via MCP)** - Current architecture: OpenCode runs separately and connects to telephony_mcp. This is the brain/body split (ADR-0010).
2. **Embed OpenCode CLI** - Call OpenCode programmatically as a subprocess from your app logic if you need to invoke it.

For the voice system, approach 1 is recommended. The telephony_mcp exposes tools (originate_call, speak, wait_for_input, etc.) that OpenCode uses.

To integrate OpenCode:
1. Run the platform: `./start_all_venv.sh`
2. Add MCP config to OpenCode pointing to `apps/telephony_mcp/dist/server.js`
3. OpenCode drives calls via MCP tools

If you want to "call" OpenCode from within the platform (e.g., trigger reasoning), you can use subprocess to invoke `opencode` CLI. But the canonical integration is OpenCode connecting to the MCP server.

## Note on Asterisk
Asterisk is NOT installed by install.sh. The platform works in simulated mode without Asterisk. For real SIP calls, install Asterisk separately and configure CALLS_BACKEND=ari.
