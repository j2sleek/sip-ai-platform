# Asterisk Capabilities Report — Phase 2A

## Environment

| Property | Value |
|----------|-------|
| OS | Ubuntu 26.04 LTS ("Resolute Raccoon") |
| Kernel | 6.17.0-PRoot-Distro |
| Runtime Environment | Ubuntu guest under PRoot-Distro inside Termux |
| Architecture | ARM64 / aarch64 |
| Host | Android device |

## Asterisk Installation

| Property | Value |
|----------|-------|
| Version | Asterisk 22.5.2~dfsg+~cs6.15.60671435-1 |
| Installation Method | Ubuntu 26.04 apt repository (`apt install asterisk`) |
| Binary Path | /usr/sbin/asterisk |
| Installation Date | 2026-07-24 |
| Build Info | Built by nobody @ buildd.debian.org on 2025-08-29 20:00:21 UTC |

## Runtime Management

| Property | Value |
|----------|-------|
| Systemd Required | ❌ No (not PID 1 under PRoot) |
| Manual Start | ✅ Yes (`asterisk -f`) |
| CLI Access | ✅ Yes (`asterisk -rx 'command'`) |
| Process Management | ✅ Custom scripts in `infra/asterisk/` |
| Start Script | `infra/asterisk/start.sh` |
| Stop Script | `infra/asterisk/stop.sh` |
| Status Script | `infra/asterisk/status.sh` |

## Module Capability Matrix

### Core Telephony

| Capability | Module | Exists | Loaded | Status |
|------------|--------|--------|--------|--------|
| PJSIP Channel Driver | chan_pjsip.so | ✅ | ✅ | AVAILABLE |
| PJSIP Core | res_pjsip.so | ✅ | ✅ | AVAILABLE |
| PJSIP Authenticator | res_pjsip_authenticator_digest.so | ✅ | ✅ | AVAILABLE |
| PJSIP Endpoint Identifier (IP) | res_pjsip_endpoint_identifier_ip.so | ✅ | ✅ | AVAILABLE |
| PJSIP Session | res_pjsip_session.so | ✅ | ✅ | AVAILABLE |
| PJSIP Registrar | res_pjsip_registrar.so | ✅ | ✅ | AVAILABLE |

### ARI (Asterisk REST Interface)

| Capability | Module | Exists | Loaded | Status |
|------------|--------|--------|--------|--------|
| ARI Core | res_ari.so | ✅ | ✅ | AVAILABLE |
| ARI Applications | res_ari_applications.so | ✅ | ✅ | AVAILABLE |
| ARI Channels | res_ari_channels.so | ✅ | ✅ | AVAILABLE |
| ARI Events | res_ari_events.so | ✅ | ✅ | AVAILABLE |
| ARI Bridges | res_ari_bridges.so | ✅ | ✅ | AVAILABLE |
| ARI Endpoints | res_ari_endpoints.so | ✅ | ✅ | AVAILABLE |

### AudioSocket

| Capability | Module | Exists | Loaded | Status |
|------------|--------|--------|--------|--------|
| AudioSocket Application | app_audiosocket.so | ✅ | ✅ | AVAILABLE |
| AudioSocket Channel | chan_audiosocket.so | ✅ | ✅ | AVAILABLE |
| AudioSocket Resource | res_audiosocket.so | ✅ | ✅ | AVAILABLE |

### WebSocket

| Capability | Module | Exists | Loaded | Status |
|------------|--------|--------|--------|--------|
| HTTP WebSocket | res_http_websocket.so | ✅ | ✅ | AVAILABLE |
| PJSIP WebSocket Transport | res_pjsip_transport_websocket.so | ✅ | ✅ | AVAILABLE |
| WebSocket Client | res_websocket_client.so | ✅ | ✅ | AVAILABLE |
| **chan_websocket** | **chan_websocket.so** | ❌ | ❌ | **NOT PRESENT** |

### RTP

| Capability | Module | Exists | Loaded | Status |
|------------|--------|--------|--------|--------|
| RTP Channel | chan_rtp.so | ✅ | ✅ | AVAILABLE |
| RTP Asterisk Stack | res_rtp_asterisk.so | ✅ | ✅ | AVAILABLE |
| Native RTP Bridging | bridge_native_rtp.so | ✅ | ✅ | AVAILABLE |
| SRTP | res_srtp.so | ✅ | ✅ | AVAILABLE |
| Multicast RTP | res_rtp_multicast.so | ✅ | ✅ | AVAILABLE |

## Network Binding

| Property | Status | Notes |
|----------|--------|-------|
| UDP Binding | ⚠️ Limited | PRoot environment may restrict UDP/RTP |
| TCP Binding | ✅ Available | Standard TCP works |
| Privileged Ports | ⚠️ Limited | May require root for ports < 1024 |
| Loopback Interface | ✅ Available | 127.0.0.1 accessible |
| Ethernet Interface | ⚠️ Limited | "No ethernet interface" warnings seen |

## Verified Commands

### Version Check
```bash
asterisk -rx 'core show version'
# Output: Asterisk 22.5.2~dfsg+~cs6.15.60671435-1
```

### Uptime Check
```bash
asterisk -rx 'core show uptime'
# Output: System uptime: X minutes, Y seconds
```

### Module Listing
```bash
asterisk -rx 'module show'
# Output: 200+ modules loaded
```

### PJSIP Transport Check
```bash
asterisk -rx 'pjsip show transports'
# Output: No objects found (expected - no transports configured yet)
```

### PJSIP Endpoint Check
```bash
asterisk -rx 'pjsip show endpoints'
# Output: No objects found (expected - no endpoints configured yet)
```

## Architecture Implications

### AudioSocket Viability
**Status: ✅ HIGHLY VIABLE**

- All three AudioSocket modules are present and loaded
- `app_audiosocket.so`, `chan_audiosocket.so`, `res_audiosocket.so`
- Available since Asterisk 18, stable in 22.x
- TCP-based protocol, simpler than raw RTP under PRoot
- Excellent for initial media transport implementation
- **Recommended as PRIMARY transport for Phase 4**

### chan_websocket Viability
**Status: ❌ NOT AVAILABLE**

- `chan_websocket.so` module is NOT present in this build
- Asterisk 22.5.2 predates the documented 22.6.0+ requirement
- Ubuntu 26.04 apt package does not include this module
- Would require source compilation to obtain
- **NOT recommended for initial implementation**

### RTP External Media Viability
**Status: ✅ VIABLE (FALLBACK)**

- All RTP modules are present and loaded
- ARI External Media support is available
- Higher implementation complexity (UDP packet timing)
- Useful for interoperability scenarios
- **Recommended as SECONDARY transport**

## PRoot/Termux Limitations

1. **UDP/RTP Reliability**: Syscall emulation may affect UDP performance
2. **Privileged Ports**: Cannot bind to ports < 1024 without root
3. **Systemd**: Not available as PID 1, requires manual process management
4. **Network Interfaces**: Limited ethernet interface detection
5. **Process Isolation**: Shared environment with other Termux processes

## Recommendations

### For Phase 2B (Telephony Foundation)
- ✅ Proceed with PJSIP endpoint configuration
- ✅ Create basic dial plan for testing
- ✅ Use loopback interface (127.0.0.1) for initial testing
- ⚠️  Document any UDP/RTP limitations

### For Phase 4 (Media Transport)
- ✅ **Primary**: Implement AudioSocket media transport first
- ❌ **Defer**: Do NOT attempt chan_websocket source compilation
- ✅ **Secondary**: Implement RTP External Media as fallback
- ✅ Keep `MediaTransport` abstraction for future chan_websocket support

### For Production Deployment
- ✅ Target Ubuntu VPS (native, not PRoot)
- ✅ Use systemd for process management
- ✅ Consider Asterisk 23.x or newer for chan_websocket
- ✅ Test UDP/RTP performance on real hardware

## Blockers

| # | Blocker | Severity | Mitigation |
|---|---------|----------|------------|
| B1 | chan_websocket not available | Medium | Use AudioSocket as primary transport |
| B2 | PRoot UDP limitations | Medium | Test thoroughly, document limitations |
| B3 | No systemd | Low | Use custom scripts (already implemented) |

## Next Phase Recommendation

**Proceed to Phase 2B: Asterisk/PJSIP Telephony Foundation**

Scope:
- Configure PJSIP endpoints (1001, 2000)
- Create basic dial plan
- Test Linphone registration
- Test echo functionality
- Verify two-way audio (loopback testing)

Do NOT attempt:
- chan_websocket compilation
- Complex RTP configurations
- Production SIP trunking
- Public internet exposure
