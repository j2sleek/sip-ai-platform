#!/bin/bash
# SIP AI Platform — Asterisk Start Script
# Safe, systemd-independent Asterisk startup for development

set -e

# Configuration
ASTERISK_BIN="/usr/sbin/asterisk"
PID_FILE="/tmp/sip-ai-asterisk.pid"
STARTUP_LOG="/tmp/sip-ai-asterisk-startup.log"

# Check if already running
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "Asterisk is already running (PID: $PID)"
    exit 1
  else
    # Stale PID file
    rm -f "$PID_FILE"
  fi
fi

# Verify Asterisk binary exists
if [ ! -x "$ASTERISK_BIN" ]; then
  echo "ERROR: Asterisk binary not found at $ASTERISK_BIN"
  exit 1
fi

# Start Asterisk in foreground mode
echo "Starting Asterisk..."
$ASTERISK_BIN -f > "$STARTUP_LOG" 2>&1 &
PID=$!

# Write PID file
echo $PID > "$PID_FILE"

echo "Asterisk started (PID: $PID)"
echo "PID file: $PID_FILE"
echo "Startup log: $STARTUP_LOG"

exit 0
