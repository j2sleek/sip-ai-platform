#!/usr/bin/env bash
#
# Start Asterisk for the SIP AI Platform (systemd-independent).
#
# Starts `asterisk -f` in the background, records a PID file, and waits until the
# CLI answers so callers can rely on ARI/PJSIP being up. Idempotent: exits 0 if
# Asterisk is already running.
#
set -euo pipefail

ASTERISK_BIN="${ASTERISK_BIN:-/usr/sbin/asterisk}"
PID_FILE="${ASTERISK_PID_FILE:-/tmp/sip-ai-asterisk.pid}"
STARTUP_LOG="${ASTERISK_LOG:-/tmp/sip-ai-asterisk-startup.log}"
WAIT_SECS="${ASTERISK_WAIT_SECONDS:-15}"

if [ ! -x "$ASTERISK_BIN" ]; then
  echo "ERROR: Asterisk binary not found at $ASTERISK_BIN" >&2
  echo "Install it with: bash infra/asterisk/configure.sh" >&2
  exit 1
fi

# Already running (tracked PID, or a responsive CLI from another launcher).
if [ -f "$PID_FILE" ]; then
  EXISTING="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$EXISTING" ] && kill -0 "$EXISTING" 2>/dev/null; then
    echo "Asterisk is already running (PID: $EXISTING)"
    exit 0
  fi
  rm -f "$PID_FILE"  # stale
fi
if "$ASTERISK_BIN" -rx "core show version" >/dev/null 2>&1; then
  echo "Asterisk is already running (untracked)"
  exit 0
fi

echo "Starting Asterisk..."
setsid "$ASTERISK_BIN" -f </dev/null > "$STARTUP_LOG" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

for _ in $(seq 1 "$WAIT_SECS"); do
  if "$ASTERISK_BIN" -rx "core show version" >/dev/null 2>&1; then
    echo "Asterisk ready (PID: $PID)"
    echo "PID file: $PID_FILE  |  log: $STARTUP_LOG"
    exit 0
  fi
  sleep 1
done

echo "WARNING: Asterisk started (PID: $PID) but did not answer within ${WAIT_SECS}s." >&2
echo "Check $STARTUP_LOG" >&2
