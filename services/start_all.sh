#!/bin/bash
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

echo "Starting Python services..."
for svc in stt llm tts vad; do
  echo "  Starting $svc..."
  cd "$ROOT/services/$svc"
  PYTHONPATH=src python3 -m $svc.server > "$ROOT/$svc.log" 2>&1 &
  echo $! > "$ROOT/$svc.pid"
done

echo "Starting control_api..."
cd "$ROOT/apps/control_api"
# Call backend: ari (Asterisk) | simulated (no telephony). Set CALL_BACKEND to override.
HOST="${HOST:-127.0.0.1}" PORT="${PORT:-4001}" CALL_BACKEND="${CALL_BACKEND:-simulated}" node dist/server.js > "$ROOT/control_api.log" 2>&1 &
echo $! > "$ROOT/control_api.pid"

sleep 2
echo "Services started. Check logs in root dir."
