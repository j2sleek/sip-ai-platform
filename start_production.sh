#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$GROQ_API_KEY" ]; then
  echo "Error: GROQ_API_KEY required"
  exit 1
fi
if [ -z "$ARI_PASSWORD" ]; then
  echo "Error: ARI_PASSWORD required (must match Asterisk ari.conf)"
  exit 1
fi

export GROQ_API_KEY
export ARI_PASSWORD
export ARI_USERNAME=${ARI_USERNAME:-voice_core}
export ARI_BASE_URL=${ARI_BASE_URL:-http://127.0.0.1:8088}
export LLM_PROVIDER=groq
export LLM_MODEL=llama-3.3-70b-versatile
export STT_PROVIDER=groq
export STT_GROQ_MODEL=whisper-large-v3-turbo
export TTS_PROVIDER=groq
export TTS_GROQ_MODEL=openai/tts-1
export TTS_GROQ_VOICE=alloy
export CALLS_BACKEND=ari
export CONTROL_API_PORT=4001 PORT=4001 HOST=127.0.0.1

pkill -f 'python3 -m' 2>/dev/null || true
pkill -f 'control_api/dist/server' 2>/dev/null || true
sleep 1

for svc in stt llm tts vad; do
  venv="$ROOT/services/$svc/.venv"
  [ ! -d "$venv" ] && echo "Run install_full.sh first" && exit 1
  cd "$ROOT/services/$svc"
  PYTHONPATH=src "$venv/bin/python" -m $svc.server > "$ROOT/$svc.log" 2>&1 &
  echo $! > "$ROOT/$svc.pid"
done

cd "$ROOT/apps/control_api"
node dist/server.js > "$ROOT/control_api.log" 2>&1 &
echo $! > "$ROOT/control_api.pid"

sleep 3
echo "Started. Health checks passing if Asterisk ARI is reachable."
