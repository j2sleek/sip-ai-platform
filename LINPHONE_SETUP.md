# Linphone Setup for Real-Time Testing

Linphone is an open-source SIP softphone for testing calls with the SIP AI Platform.

## Install Linphone

### Linux (Ubuntu/Debian)
```bash
sudo apt install linphone
```

### Other platforms
- macOS: https://www.linphone.org/en/desktop-app
- Windows: https://www.linphone.org/en/desktop-app
- Android/iOS: App stores

## SIP Account Configuration (Asterisk)

The configured test account in Asterisk is **Extension 1001**:

| Field | Value |
|---|---|
| Extension/Username | `1001` |
| Password | `1001_secure_password_here` |
| Domain/Server | The host's IP address — run `hostname -I` (e.g. `10.214.100.129`), or `127.0.0.1` for a local softphone |
| Transport | UDP (port 5060) |
| Context | `internal` |
| Allowed codecs | ulaw, alaw |

**Auth Flow:** Linphone registers to Asterisk via PJSIP using username/password authentication (`auth=1001-auth`). Asterisk challenges with digest auth and Linphone responds, establishing registration. Once registered, you can call extensions like 2000 (AI echo test), 4000 (AudioSocket), etc.

### Linphone Setup Steps

1. Open Linphone → Settings → Accounts → Add Account
2. Account type: SIP
3. Username: `1001`
4. Password: `1001_secure_password_here`
5. Domain: `your-asterisk-ip` (e.g., `192.168.1.10`)
6. Transport: UDP
7. Save - registration should succeed if Asterisk is running

### Test Extensions (from Asterisk config)

- **2000**: AI service placeholder - answers, plays hello-world, then Echo() for audio testing
- **4000**: AudioSocket test (for Phase 3 - connects to port 9019)
- **1002**: Direct echo test
- **3000**: DTMF test
- **1001**: Your Linphone endpoint

### Auth Flow Explanation

1. Linphone sends REGISTER to `sip:domain`
2. Asterisk responds with 401 Unauthorized + WWW-Authenticate (digest challenge)
3. Linphone sends REGISTER again with Authorization header (MD5 of credentials, nonce, URI)
4. Asterisk validates and responds 200 OK (registered)
5. For calls: INVITE flows similarly with digest auth if required; for registered endpoints in same context it's typically allowed

## Recommended Test Flow

1. Start services (mock mode works without SIP):
```bash
# Start in different terminals or background
cd services/stt && python -m stt.server &
cd services/llm && python -m llm.server &
cd services/tts && python -m tts.server &
cd services/vad && python -m vad.server &
cd apps/control_api && npm start &
```

2. Use simulated backend (no Asterisk needed):
```bash
export CALL_BACKEND=simulated
```

3. Test with demo:
```bash
node apps/telephony_mcp/scripts/demo-voice-loop.mjs
```

## Start the platform

Asterisk is installed and configured by the one-install wrapper:

```bash
./install_full.sh          # venvs, builds, Asterisk install + PJSIP/ARI config
./start_production.sh      # Asterisk + voice_core + control_api + AI services
```

The stack then drives real calls through `CALL_BACKEND=ari`. To exercise the AI
pipeline without any telephony, start with `CALL_BACKEND=simulated` instead.

### Smoke test without a phone

```bash
# Originate a real call into the dialplan (Local channel), then hang up
curl -X POST http://127.0.0.1:4001/api/v1/calls \
  -H 'Content-Type: application/json' \
  -d '{"to":"Local/2000@internal","from":"agent"}'
```

## Notes
- Production backend is `ari` (Asterisk). `simulated` is available for offline
  AI-pipeline testing (and is what the automated tests use).
- The `1001` password in `infra/asterisk/config/pjsip.conf` is a development
  placeholder — change it before exposing the host.
- Cloud AI providers are optional; the `mock` providers give deterministic
  behavior for local testing.
