#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "=== SIP AI Platform - Full Production Install ==="

# Python venvs and deps
for svc in stt llm tts vad; do
  venv="$ROOT/services/$svc/.venv"
  if [ ! -d "$venv" ]; then
    python3 -m venv "$venv"
  fi
  "$venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
  [ -f "$ROOT/services/$svc/requirements.txt" ] && "$venv/bin/pip" install -r "$ROOT/services/$svc/requirements.txt"
done

# Node deps and build
for app in apps/control_api apps/telephony_mcp; do
  (cd "$ROOT/$app" && npm install --no-audit --no-fund)
done
(cd "$ROOT/apps/control_api" && npx tsc --outDir dist)
(cd "$ROOT/apps/telephony_mcp" && npx tsc --outDir dist)

# Check for Asterisk
if ! command -v asterisk >/dev/null 2>&1; then
  echo "WARNING: Asterisk not installed. For production SIP, install Asterisk on this host."
  echo "  Ubuntu/Debian: sudo apt install asterisk asterisk-pjsip"
fi

echo "=== Full install complete ==="
echo "Set GROQ_API_KEY and ARI_PASSWORD, then run: bash start_all_venv.sh"
