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
| Domain/Server | Your Asterisk server IP (e.g., `10.171.202.39` as configured, or `127.0.0.1` if local) |
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
export CALLS_BACKEND=simulated
```

3. Test with demo:
```bash
node apps/telephony_mcp/scripts/demo-voice-loop.mjs
```

## Notes
- Default mode is `simulated` - no real SIP needed for testing the AI pipeline
- For live SIP calls, configure Asterisk/ARI and set `CALLS_BACKEND=ari`
- Linphone config depends on your SIP server setup; not needed for simulated testing
- All cloud providers are optional; mock gives deterministic behavior
