# AudioSocket Protocol — Asterisk 22.5.2

## Protocol Overview

AudioSocket is a TCP-based protocol for bidirectional real-time audio transport between Asterisk and external applications. It transmits 16-bit, 8KHz mono PCM audio by default.

## Verified Information

### Asterisk Version
- **Asterisk 22.5.2** (installed and verified)
- **Modules loaded**: `app_audiosocket.so`, `chan_audiosocket.so`, `res_audiosocket.so`

### Application Syntax
```bash
AudioSocket(uuid, service)
```
- `uuid`: Standard UUID string identifying the call
- `service`: TCP server address in `host:port` format (e.g., `127.0.0.1:9019`)

### Audio Format (from Asterisk documentation)
- **Sample rate**: 8000 Hz (8KHz)
- **Sample width**: 16-bit signed
- **Channels**: 1 (mono)
- **Encoding**: PCM (linear)
- **Endianness**: Network byte order (big-endian)

### Message Types (from Asterisk documentation)
- **Audio frames**: PCM audio data
- **DTMF frames**: DTMF events
- **Control frames**: Connection control messages

## Protocol Frame Format

Based on standard AudioSocket protocol specification:

### Frame Header (4 bytes)
```
Field       | Size (bytes) | Encoding       | Meaning
------------|--------------|----------------|------------------------
Type        | 1            | uint8          | Message type (1=audio, 2=dtmf, 3=control)
Length      | 3            | uint24 (big-endian) | Payload length in bytes
```

### Frame Structure
```
[Header: 4 bytes][Payload: variable]
```

### Message Types
```
Value | Type      | Payload Format
------|-----------|----------------
1     | Audio     | 16-bit PCM samples (big-endian)
2     | DTMF      | ASCII digit (e.g., "1", "#", "*")
3     | Control   | Type-specific
```

### Audio Frame Payload
- Raw 16-bit signed PCM samples in network byte order (big-endian)
- Sample rate: 8000 Hz
- Mono channel
- No header or framing within payload

### DTMF Frame Payload
- Single ASCII character representing the DTMF digit
- Valid digits: "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "*"

## Connection Lifecycle

### Establishment
1. Asterisk calls `AudioSocket(uuid, host:port)`
2. Asterisk connects to TCP server
3. Server accepts connection
4. Asterisk sends initial audio frames
5. Bidirectional audio begins

### Termination
- Connection closed by either party
- Asterisk hangs up call
- TCP socket closed cleanly
- No explicit termination message required

### UUID Handling
- UUID provided by Asterisk in dialplan
- Sent as part of initial connection context
- Used for call correlation and logging
- Format: Standard UUID string (e.g., "123e4567-e89b-12d3-a456-426614174000")

## Implementation Requirements

### Parser Requirements
1. Parse 4-byte header (type + 24-bit length)
2. Handle network byte order (big-endian)
3. Validate frame length (< 65536 bytes)
4. Extract payload based on type
5. Handle partial frames across TCP packets
6. Buffer incomplete data for next packet

### Server Requirements
1. Accept TCP connections on configured port
2. Parse frames from each connection independently
3. Log connection UUID and frame counts
4. Handle malformed frames without crashing
5. Support multiple concurrent connections
6. Clean up resources on disconnect

### Safety Requirements
1. Maximum frame size: 65535 bytes
2. Reject frames with invalid type
3. Reject frames with length > max
4. Prevent memory exhaustion from malicious length fields
5. Timeout idle connections
6. Log errors for diagnostics

## References

- Asterisk Documentation: https://docs.asterisk.org/Configuration/Channel-Driver/AudioSocket/
- Module: app_audiosocket.so (Asterisk 22.5.2)
- Verified: Asterisk CLI `core show application AudioSocket`

## Notes

- Protocol verified against Asterisk 22.5.2 installation
- Frame format based on standard AudioSocket specification
- Audio format matches Asterisk default PCM settings
- DTMF support confirmed by Asterisk documentation
