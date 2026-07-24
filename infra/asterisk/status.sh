#!/bin/bash
# SIP AI Platform — Asterisk Status Script
# Report Asterisk installation and runtime status

set -e

# Configuration
ASTERISK_BIN="/usr/sbin/asterisk"
PID_FILE="/tmp/sip-ai-asterisk.pid"

echo "=== Asterisk Status Report ==="
echo

# Binary check
echo "1. Binary:"
if [ -x "$ASTERISK_BIN" ]; then
  echo "   ✅ Found: $ASTERISK_BIN"
else
  echo "   ❌ Not found: $ASTERISK_BIN"
  exit 1
fi

# Version check
echo
echo "2. Version:"
VERSION=$($ASTERISK_BIN -rx 'core show version' 2>&1 | grep -v "No ethernet interface" | head -1)
if [ -n "$VERSION" ]; then
  echo "   ✅ $VERSION"
else
  echo "   ⚠️  Could not determine version"
fi

# Process status
echo
echo "3. Process Status:"
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "   ✅ Running (PID: $PID)"
    echo "   ✅ PID file: $PID_FILE"
  else
    echo "   ⚠️  PID file exists but process not running (stale PID)"
  fi
else
  echo "   ❌ Not running (no PID file)"
fi

# CLI check
echo
echo "4. CLI Availability:"
CLI_TEST=$($ASTERISK_BIN -rx 'core show uptime' 2>&1 | grep -v "No ethernet interface" | head -1)
if [ -n "$CLI_TEST" ]; then
  echo "   ✅ CLI working"
  echo "   ✅ Uptime: $CLI_TEST"
else
  echo "   ❌ CLI not responding"
fi

# Module check
echo
echo "5. Key Modules:"
echo "   PJSIP:         $(asterisk -rx 'module show like chan_pjsip' 2>&1 | grep -v "No ethernet" | grep -c 'chan_pjsip.so' || echo '0') module(s)"
echo "   ARI:           $(asterisk -rx 'module show like res_ari' 2>&1 | grep -v "No ethernet" | grep -c 'res_ari.so' || echo '0') module(s)"
echo "   AudioSocket:   $(asterisk -rx 'module show like audiosocket' 2>&1 | grep -v "No ethernet" | grep -c 'app_audiosocket.so' || echo '0') module(s)"

echo
echo "=== End Report ==="
