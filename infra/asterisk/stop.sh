#!/bin/bash
# SIP AI Platform — Asterisk Stop Script
# Safe shutdown of Asterisk instance managed by this project

set -e

# Configuration
PID_FILE="/tmp/sip-ai-asterisk.pid"

# Check if PID file exists
if [ ! -f "$PID_FILE" ]; then
  echo "Asterisk is not running (no PID file found)"
  exit 0
fi

# Read PID
PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
if [ -z "$PID" ]; then
  echo "PID file is empty"
  rm -f "$PID_FILE"
  exit 0
fi

# Check if process exists
if ! kill -0 "$PID" 2>/dev/null; then
  echo "Asterisk process $PID not found (stale PID file)"
  rm -f "$PID_FILE"
  exit 0
fi

# Verify it's actually Asterisk
PROCESS_NAME=$(ps -p "$PID" -o comm= 2>/dev/null || echo "")
if [ "$PROCESS_NAME" != "asterisk" ]; then
  echo "ERROR: PID $PID is not Asterisk (found: $PROCESS_NAME)"
  exit 1
fi

# Stop Asterisk gracefully
echo "Stopping Asterisk (PID: $PID)..."
kill -TERM "$PID"

# Wait for shutdown (max 10 seconds)
COUNT=0
while kill -0 "$PID" 2>/dev/null && [ $COUNT -lt 20 ]; do
  sleep 0.5
  COUNT=$((COUNT + 1))
done

if kill -0 "$PID" 2>/dev/null; then
  echo "WARNING: Asterisk did not stop gracefully, sending SIGKILL"
  kill -KILL "$PID"
  sleep 1
fi

# Remove PID file
rm -f "$PID_FILE"

echo "Asterisk stopped successfully"
exit 0
