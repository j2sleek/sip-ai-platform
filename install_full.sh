#!/usr/bin/env bash
#
# One-install wrapper for the SIP AI Platform.
#
# Installs every runtime and dependency needed to run the full stack:
#   * Python services (stt, llm, tts, vad) — each in its own virtualenv
#   * Node/TypeScript apps (control_api, telephony_mcp) — deps + build
#   * Elixir app (voice_core) — deps + compile
#   * Asterisk — package install + platform PJSIP/ARI configuration
#
# Environment:
#   ARI_PASSWORD          ARI password (generated and stored locally if omitted)
#   SKIP_ASTERISK=1       skip the Asterisk install/configure step
#   SKIP_VOICE_CORE=1     skip the Elixir build
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "=== SIP AI Platform — full install ==="

# ─── Python services (isolated virtualenv per service) ──────────────────────
for svc in stt llm tts vad; do
  echo "--- python: $svc ---"
  venv="$ROOT/services/$svc/.venv"
  [ -d "$venv" ] || python3 -m venv "$venv"
  "$venv/bin/python" -m pip install --upgrade pip >/dev/null
  if [ -s "$ROOT/services/$svc/requirements.txt" ]; then
    "$venv/bin/python" -m pip install -r "$ROOT/services/$svc/requirements.txt"
  fi
done

# ─── Node / TypeScript apps ─────────────────────────────────────────────────
for app in control_api telephony_mcp; do
  echo "--- node: $app ---"
  ( cd "$ROOT/apps/$app" && npm install --no-audit --no-fund && npm run build )
done

# ─── Elixir app ─────────────────────────────────────────────────────────────
if [ "${SKIP_VOICE_CORE:-0}" = "1" ]; then
  echo "--- skipping voice_core (SKIP_VOICE_CORE=1) ---"
elif command -v mix >/dev/null 2>&1; then
  echo "--- elixir: voice_core ---"
  (
    cd "$ROOT/apps/voice_core"
    mix local.hex --force >/dev/null
    mix local.rebar --force >/dev/null
    mix deps.get
    mix compile
  )
else
  echo "WARNING: Elixir/mix not found — voice_core will not run until installed."
fi

# ─── Asterisk (telephony + ARI) ─────────────────────────────────────────────
if [ "${SKIP_ASTERISK:-0}" = "1" ]; then
  echo "--- skipping Asterisk (SKIP_ASTERISK=1) ---"
else
  bash "$ROOT/infra/asterisk/configure.sh"
fi

echo
echo "=== install complete ==="
echo "Next: configure AI provider credentials, then start the stack:"
echo "  export GROQ_API_KEY=...   # default LLM/STT/TTS provider"
echo "  ./start_production.sh"
