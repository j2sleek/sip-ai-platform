#!/bin/sh
# SIP AI Platform — check health of locally running services.
#
# Probes GET /health on the HTTP services (control_api, stt, llm, tts) and the
# in-process health of voice_core. Services that are not running are reported as
# DOWN, not as errors — this script never starts services and never requires
# Asterisk or AI models.
#
# Exit code: 0 if every probed service that IS running is healthy; non-zero only
# if a running service reports unhealthy. Not-running services do not fail it.
#
# Usage:  sh scripts/health-all.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -d /opt/elixir/bin ] && PATH="/opt/elixir/bin:$PATH"
export PATH

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G="$(printf '\033[32m')"; R="$(printf '\033[31m')"; Y="$(printf '\033[33m')"; Z="$(printf '\033[0m')"
else
  G=""; R=""; Y=""; Z=""
fi

UNHEALTHY=""

# http_health NAME URL
http_health() {
  _name="$1"; _url="$2"
  if command -v curl >/dev/null 2>&1; then
    _body="$(curl -fsS --max-time 3 "$_url" 2>/dev/null)"
    _rc=$?
  else
    _body="$(python3 -c "import sys,urllib.request; sys.stdout.write(urllib.request.urlopen('$_url',timeout=3).read().decode())" 2>/dev/null)"
    _rc=$?
  fi
  if [ "$_rc" -ne 0 ] || [ -z "$_body" ]; then
    printf '%s[DOWN]%s %-12s %s (not running)\n' "$Y" "$Z" "$_name" "$_url"
    return 0
  fi
  if printf '%s' "$_body" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    printf '%s[UP]  %s %-12s %s\n' "$G" "$Z" "$_name" "$_body"
  else
    printf '%s[BAD] %s %-12s %s\n' "$R" "$Z" "$_name" "$_body"
    UNHEALTHY="$UNHEALTHY $_name"
  fi
}

printf 'SIP AI Platform — service health\n'

# HTTP services (defaults match each service's .env.example)
http_health "control_api" "http://127.0.0.1:${CONTROL_API_PORT:-4000}/health"
http_health "stt"         "http://127.0.0.1:${STT_PORT:-5001}/health"
http_health "llm"         "http://127.0.0.1:${LLM_PORT:-5002}/health"
http_health "tts"         "http://127.0.0.1:${TTS_PORT:-5003}/health"

# voice_core: in-process health (no HTTP server in Phase 1)
if command -v mix >/dev/null 2>&1; then
  _vc="$(cd "$ROOT/apps/voice_core" && mix run -e 'IO.puts(inspect(VoiceCore.health()))' 2>/dev/null | tail -1)"
  case "$_vc" in
    *:ok*) printf '%s[UP]  %s %-12s %s\n' "$G" "$Z" "voice_core" ":ok (in-process)" ;;
    *)     printf '%s[DOWN]%s %-12s (mix run health check unavailable)\n' "$Y" "$Z" "voice_core" ;;
  esac
else
  printf '%s[DOWN]%s %-12s (mix not found)\n' "$Y" "$Z" "voice_core"
fi

if [ -n "$UNHEALTHY" ]; then
  printf '\n%sUnhealthy running services:%s%s\n' "$R" "$Z" "$UNHEALTHY"
  exit 1
fi
printf '\nAll running services healthy (services shown as DOWN are simply not started).\n'
exit 0
