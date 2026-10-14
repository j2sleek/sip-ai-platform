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

## Troubleshooting

### The callee sees "Anonymous" instead of a caller ID

Asterisk's outbound `From` is built from the PJSIP endpoint's identity. Two
things matter:

- **Do not set `from_user` on the endpoint.** PJSIP's `from_user` *overrides*
  the caller ID, producing `From: "Anonymous" <sip:1001@asterisk>` (or no
  display name at all). Leave it unset.
- **Set the endpoint `callerid`**, e.g.
  `callerid=AI Assistant <2000>` in `[1001]`. That becomes
  `From: "AI Assistant" <sip:2000@asterisk>`.
- Per call, `control_api` also sends an ARI `callerId` (default
  `ARI_CALLER_ID`, e.g. `"AI Assistant" <2000>`); a request `from` overrides
  it. This only takes effect when `from_user` is unset.

Verify without audio with the ARI interface:

```bash
PW=$(cat infra/asterisk/.ari_password)
curl -u "voice_core:$PW" -X POST \
  "http://127.0.0.1:8088/ari/channels?channelId=probe&endpoint=PJSIP%2F1001&app=probe&callerId=%22AI%20Assistant%22%20%3C2000%3E&timeout=30"
```

The client's softphone log shows the `From` it received.

### Call clarity is limited / audio sounds robotic

- Asterisk is configured for **G.711 (ulaw/alaw) at 8 kHz** — narrowband
  "telephone quality" is the ceiling. For wideband audio, add `g722`/`opus` on
  both the endpoint and the client, but note the AudioSocket core is 8 kHz.
- On the Linphone side, turn the call off **speakerphone** (echo + room noise),
  and **disable call recording** (`.mkv`/Opus encoding adds CPU load and can
  cause glitches).
- The server resamples TTS (24 kHz WAV) to 8 kHz with an anti-aliased
  windowed-sinc filter, so high-frequency fold-back is not a source of harshness.

### Turns feel delayed

SIP/RTP between Linphone and Asterisk is local (sub-ms), so the client is not
the latency source once media is set up. The dominant per-turn latency is the
cloud AI round-trip (STT → LLM → TTS) over the host's uplink. Confirm end-to-end
latency with `run/stt.log`, `run/llm.log`, `run/tts.log` (each line has
`elapsed_ms`).

The STT/LLM/TTS services now reuse keep-alive HTTP connections to their cloud
provider (`docs/DECISIONS.md` ADR-0014), so a turn no longer pays DNS + TCP +
TLS setup on every request. If per-turn latency regresses, check the AI logs for
reconnect/retry noise and confirm keep-alive is on (`HTTP_KEEPALIVE`, default
`1`); set `HTTP_KEEPALIVE=0` only to A/B the difference.

