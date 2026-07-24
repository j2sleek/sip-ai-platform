# Asterisk Infrastructure

This directory contains scripts and configuration for managing Asterisk in the SIP AI Platform.

## Purpose

Provide safe, systemd-independent Asterisk lifecycle management for the development environment (Ubuntu under PRoot/Termux).

## Scripts

### `start.sh`

Starts Asterisk in the foreground (for development).

**Usage:**
```bash
./start.sh
```

**Behavior:**
- Checks if Asterisk is already running
- Starts Asterisk with `asterisk -f` (foreground mode)
- Creates a PID file at `/tmp/sip-ai-asterisk.pid`
- Logs startup errors to `/tmp/sip-ai-asterisk-startup.log`

### `stop.sh`

Stops the Asterisk instance managed by this project.

**Usage:**
```bash
./stop.sh
```

**Behavior:**
- Reads PID from `/tmp/sip-ai-asterisk.pid`
- Sends SIGTERM to the process
- Verifies process termination
- Removes the PID file
- Handles already-stopped state gracefully

### `status.sh`

Reports Asterisk status.

**Usage:**
```bash
./status.sh
```

**Output includes:**
- Asterisk binary path
- Asterisk version
- Process status (running/stopped)
- PID (if running)
- CLI availability

## Safety Rules

1. **No `killall` or `pkill`**: Scripts target only the PID file, never kill by name.
2. **PID file isolation**: Uses `/tmp/sip-ai-asterisk.pid` to avoid conflicts.
3. **Graceful shutdown**: Uses SIGTERM, not SIGKILL.
4. **No systemd dependency**: Works in PRoot/Termux environment.

## Environment Notes

- Asterisk 22.5.2 is installed from Ubuntu 26.04 apt repository
- Running under PRoot/Termux on ARM64
- No systemd available (not PID 1)
- UDP/RTP networking may have limitations under PRoot

## Module Capabilities (Verified)

| Capability | Module | Status |
|------------|--------|--------|
| PJSIP | chan_pjsip.so | ✅ Loaded |
| ARI | res_ari.so | ✅ Loaded |
| AudioSocket | app_audiosocket.so | ✅ Loaded |
| AudioSocket | chan_audiosocket.so | ✅ Loaded |
| AudioSocket | res_audiosocket.so | ✅ Loaded |
| WebSocket (PJSIP transport) | res_pjsip_transport_websocket.so | ✅ Loaded |
| chan_websocket | chan_websocket.so | ❌ Not present |
| RTP | chan_rtp.so | ✅ Loaded |

## Usage in Development

```bash
# Start Asterisk
cd /root/sip-ai-platform/infra/asterisk
./start.sh

# Check status
./status.sh

# Stop Asterisk
./stop.sh
```

## Production Considerations

These scripts are for development only. Production deployments should use:
- systemd service files (on Ubuntu VPS)
- Proper user permissions
- Firewall rules
- Secure configuration
