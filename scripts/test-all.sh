#!/bin/sh
# SIP AI Platform — run all runtime test suites.
#
# Tests Elixir (voice_core), Python (stt/llm/tts), and Node (control_api).
# Fails (exit 1) if ANY suite fails. Prints clear per-service banners.
# Does not touch Asterisk, AI models, or /root/chartcapture-api.
#
# Usage:  sh scripts/test-all.sh

# No `set -e`: we run every suite and aggregate results.

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure the Elixir toolchain is reachable even in a non-login shell.
[ -d /opt/elixir/bin ] && PATH="/opt/elixir/bin:$PATH"
export PATH

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G="$(printf '\033[32m')"; R="$(printf '\033[31m')"; B="$(printf '\033[1;34m')"; Z="$(printf '\033[0m')"
else
  G=""; R=""; B=""; Z=""
fi

FAILED=""

banner() { printf '\n%s========== %s ==========%s\n' "$B" "$1" "$Z"; }
record() { # $1 = name, $2 = exit code
  if [ "$2" -eq 0 ]; then
    printf '%s[PASS]%s %s\n' "$G" "$Z" "$1"
  else
    printf '%s[FAIL]%s %s (exit %s)\n' "$R" "$Z" "$1" "$2"
    FAILED="$FAILED $1"
  fi
}

# --- Elixir: voice_core -----------------------------------------------------
banner "voice_core (Elixir)"
if command -v mix >/dev/null 2>&1; then
  (cd "$ROOT/apps/voice_core" && mix deps.get >/dev/null 2>&1 && \
     mix compile --warnings-as-errors && mix test && mix format --check-formatted)
  record "voice_core" $?
else
  record "voice_core (mix not found)" 1
fi

# --- Python: stt / llm / tts ------------------------------------------------
for svc in stt llm tts; do
  banner "$svc (Python)"
  if command -v python3 >/dev/null 2>&1; then
    (cd "$ROOT/services/$svc" && PYTHONPATH=src python3 -m unittest discover -s tests)
    record "$svc" $?
  else
    record "$svc (python3 not found)" 1
  fi
done

# --- Node: control_api ------------------------------------------------------
banner "control_api (Node.js)"
if command -v npm >/dev/null 2>&1; then
  if [ -d "$ROOT/apps/control_api/node_modules" ]; then
    (cd "$ROOT/apps/control_api" && npm run build && npm test)
    record "control_api" $?
  else
    printf '%s[SKIP]%s control_api: run `npm install` in apps/control_api first\n' "$R" "$Z"
    FAILED="$FAILED control_api(no-node_modules)"
  fi
else
  record "control_api (npm not found)" 1
fi

# --- Summary ----------------------------------------------------------------
banner "SUMMARY"
if [ -n "$FAILED" ]; then
  printf '%sFAILED:%s%s\n' "$R" "$Z" "$FAILED"
  exit 1
fi
printf '%sAll test suites passed.%s\n' "$G" "$Z"
exit 0
