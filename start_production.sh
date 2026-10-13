#!/usr/bin/env bash
#
# Start the full SIP AI Platform stack for production-like operation:
#
#   Asterisk (ARI/PJSIP)  ──▶  voice_core (Elixir/OTP)
#        ▲                          │  HTTP
#        │ ARI originate            ▼
#   control_api (Node)  ◀────  AI services (Python: stt/llm/tts/vad)
#
# Provider selection is environment-driven and fully overridable, so alternative
# backends (e.g. a self-hosted nexus-ai-gateway) can be plugged in without code
# changes. Groq is the default cloud provider.
#
# Required:
#   ARI_PASSWORD        (or infra/asterisk/.ari_password from configure.sh)
#   GROQ_API_KEY        when any provider is set to "groq"
#
# Common overrides:
#   LLM_PROVIDER STT_PROVIDER TTS_PROVIDER
#   LLM_MODEL STT_GROQ_MODEL TTS_GROQ_MODEL TTS_GROQ_VOICE
#   PORT HOST ARI_USERNAME ARI_APP ARI_BASE_URL
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SIP_AI_RUN_DIR:-$ROOT/run}"
mkdir -p "$RUN_DIR"

log() { printf '[start] %s\n' "$*"; }
die() { printf '[start] ERROR: %s\n' "$*" >&2; exit 1; }

# ─── ARI credentials ────────────────────────────────────────────────────────
if [ -z "${ARI_PASSWORD:-}" ] && [ -f "$ROOT/infra/asterisk/.ari_password" ]; then
  ARI_PASSWORD="$(cat "$ROOT/infra/asterisk/.ari_password")"
fi
[ -n "${ARI_PASSWORD:-}" ] || die "ARI_PASSWORD unset and no infra/asterisk/.ari_password; run infra/asterisk/configure.sh"

export ARI_PASSWORD
export ARI_USERNAME="${ARI_USERNAME:-voice_core}"
export ARI_APP="${ARI_APP:-voice_core}"
export ARI_APP_NAME="${ARI_APP_NAME:-$ARI_APP}"
export ARI_BASE_URL="${ARI_BASE_URL:-http://127.0.0.1:8088}"
export ARI_ENABLED=true
export CALL_BACKEND=ari

# ─── AI providers (overridable; Groq by default) ────────────────────────────
export LLM_PROVIDER="${LLM_PROVIDER:-groq}"
export STT_PROVIDER="${STT_PROVIDER:-groq}"
export TTS_PROVIDER="${TTS_PROVIDER:-groq}"
export LLM_MODEL="${LLM_MODEL:-llama-3.3-70b-versatile}"
export STT_GROQ_MODEL="${STT_GROQ_MODEL:-whisper-large-v3-turbo}"
export TTS_GROQ_MODEL="${TTS_GROQ_MODEL:-openai/tts-1}"
export TTS_GROQ_VOICE="${TTS_GROQ_VOICE:-alloy}"

for provider in "$LLM_PROVIDER" "$STT_PROVIDER" "$TTS_PROVIDER"; do
  if [ "$provider" = "groq" ] && [ -z "${GROQ_API_KEY:-}" ]; then
    die "GROQ_API_KEY is required when a provider is set to 'groq'"
  fi
done

# ─── Ports ──────────────────────────────────────────────────────────────────
export PORT="${PORT:-4001}"
export HOST="${HOST:-127.0.0.1}"

# ─── Helpers ────────────────────────────────────────────────────────────────
stop_pidfile() {
  local pidfile="$1" pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "stopping previous process (PID $pid) from $(basename "$pidfile")"
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pidfile"
}

wait_health() {
  local name="$1" url="$2" out
  for _ in $(seq 1 "${HEALTH_WAIT_SECONDS:-20}"); do
    if out="$(curl -fsS "$url" 2>/dev/null)"; then
      log "$name healthy: $out"
      return 0
    fi
    sleep 1
  done
  return 1
}

start_python() {
  local svc="$1" venv="$ROOT/services/$1/.venv"
  [ -x "$venv/bin/python" ] || die "missing venv for $svc; run ./install_full.sh"
  # setsid + /dev/null detach the service so it does not hold the caller's stdio.
  ( cd "$ROOT/services/$svc" && PYTHONPATH=src setsid "$venv/bin/python" -m "$svc.server" \
      </dev/null > "$RUN_DIR/$svc.log" 2>&1 & echo $! > "$RUN_DIR/$svc.pid" )
  log "started $svc (PID $(cat "$RUN_DIR/$svc.pid"))"
}

# ─── Stop any previously-started instances ──────────────────────────────────
for name in stt llm tts vad control_api voice_core; do
  stop_pidfile "$RUN_DIR/$name.pid"
done

# ─── Asterisk ───────────────────────────────────────────────────────────────
if asterisk -rx "core show version" >/dev/null 2>&1; then
  log "Asterisk already running"
else
  log "starting Asterisk"
  bash "$ROOT/infra/asterisk/start.sh"
fi

# ─── AI services (Python) ───────────────────────────────────────────────────
start_python stt
start_python llm
start_python tts
start_python vad

# ─── control_api (Node) ─────────────────────────────────────────────────────
[ -f "$ROOT/apps/control_api/dist/server.js" ] || die "control_api not built; run ./install_full.sh"
( cd "$ROOT/apps/control_api" && setsid node dist/server.js </dev/null > "$RUN_DIR/control_api.log" 2>&1 & echo $! > "$RUN_DIR/control_api.pid" )
log "control_api starting (PID $(cat "$RUN_DIR/control_api.pid"))"

# ─── voice_core (Elixir/OTP) ────────────────────────────────────────────────
if command -v mix >/dev/null 2>&1; then
  ( cd "$ROOT/apps/voice_core" && MIX_ENV="${MIX_ENV:-prod}" setsid mix run --no-halt \
      </dev/null > "$RUN_DIR/voice_core.log" 2>&1 & echo $! > "$RUN_DIR/voice_core.pid" )
  log "voice_core starting (PID $(cat "$RUN_DIR/voice_core.pid"))"
else
  log "WARNING: mix not found; skipping voice_core"
fi

# ─── Verify ─────────────────────────────────────────────────────────────────
echo
status=0
wait_health "stt"         "http://127.0.0.1:5001/health" || status=1
wait_health "llm"         "http://127.0.0.1:5002/health" || status=1
wait_health "tts"         "http://127.0.0.1:5003/health" || status=1
wait_health "vad"         "http://127.0.0.1:5004/health" || status=1
wait_health "control_api" "http://${HOST}:${PORT}/health" || status=1

if curl -fsS -u "${ARI_USERNAME}:${ARI_PASSWORD}" "${ARI_BASE_URL}/ari/asterisk/info" >/dev/null 2>&1; then
  log "Asterisk ARI reachable at ${ARI_BASE_URL}/ari (user ${ARI_USERNAME})"
else
  log "WARNING: Asterisk ARI not reachable at ${ARI_BASE_URL}/ari"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "=== SIP AI Platform is up ==="
  echo "control_api : http://${HOST}:${PORT}  (POST /api/v1/calls)"
  echo "logs        : $RUN_DIR/*.log"
else
  echo "=== started with warnings — check logs in $RUN_DIR ==="
fi
exit "$status"
