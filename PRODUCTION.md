# Production Deployment

The platform runs as a set of loosely-coupled services. two scripts cover the
whole lifecycle:

| Script | Purpose |
|---|---|
| `install_full.sh` | One-install: Python venvs, Node build, Elixir build, **Asterisk install + configuration** |
| `start_production.sh` | Start the full stack (Asterisk → voice_core → control_api → stt/llm/tts/vad) and verify health |

## 1. Install everything

```bash
./install_full.sh
```

This script:

- Creates an isolated virtualenv per Python service (`services/{stt,llm,tts,vad}/.venv`).
- Installs Node dependencies and builds `control_api` + `telephony_mcp`.
- Fetches Elixir dependencies and compiles `voice_core`.
- Installs the Asterisk package (when missing) and renders
  `/etc/asterisk/{pjsip,extensions,ari,http}.conf`.

Skip individual steps if needed:

```bash
SKIP_ASTERISK=1   ./install_full.sh   # don't touch Asterisk
SKIP_VOICE_CORE=1 ./install_full.sh   # don't build the Elixir app
```

### ARI credentials

`install_full.sh` delegates Asterisk setup to `infra/asterisk/configure.sh`,
which:

- Uses `ARI_PASSWORD` when provided, otherwise generates a strong password and
  stores it in `infra/asterisk/.ari_password` (git-ignored, `chmod 600`).
- Registers the `voice_core` ARI user and enables the HTTP/ARI listener on
  `:8088`.
- Backs up any pre-existing `/etc/asterisk/*.conf` to `*.pre-sip-ai.bak`.

Re-run it any time to re-render configuration:

```bash
ARI_PASSWORD=... bash infra/asterisk/configure.sh
```

## 2. Configure AI providers

Provider selection is environment-driven, so alternative backends (for example a
self-hosted `nexus-ai-gateway`) can be plugged in without code changes. Providers
run behind the `stt` / `llm` / `tts` interfaces.

Groq (the default cloud provider):

```bash
export GROQ_API_KEY=gsk_...
```

Any supported combination works, e.g.:

```bash
export LLM_PROVIDER=gemini     GEMINI_API_KEY=...
export STT_PROVIDER=openrouter OPENROUTER_API_KEY=...
export TTS_PROVIDER=cartesia   CARTESIA_API_KEY=...
```

See [`docs/TESTING-WITH-REAL-PROVIDERS.md`](docs/TESTING-WITH-REAL-PROVIDERS.md)
for the full provider/model matrix.

## 3. Start the stack

```bash
export GROQ_API_KEY=gsk_...
./start_production.sh
```

The script (re)starts every component, waits for health checks, verifies ARI
reachability, and writes logs + PID files under `run/`.

| Component | Endpoint |
|---|---|
| `control_api` | `http://127.0.0.1:4001` (`POST /api/v1/calls`) |
| `stt` / `llm` / `tts` / `vad` | `:5001` / `:5002` / `:5003` / `:5004` |
| Asterisk ARI | `http://127.0.0.1:8088/ari` |

Override listeners with `HOST` / `PORT`, and the backend with
`CALL_BACKEND=ari|simulated`.

## 4. Requirements

- Python 3.10+, Node 20+ (tested on 26), Elixir 1.18 / Erlang OTP 27.
- Asterisk 22 (installed by `install_full.sh`, or run `infra/asterisk/configure.sh`).
- A SIP client such as Linphone — see [`LINPHONE_SETUP.md`](LINPHONE_SETUP.md).

## 5. Operations

```bash
# Asterisk lifecycle
infra/asterisk/start.sh
infra/asterisk/status.sh
infra/asterisk/stop.sh

# Tail logs
tail -f run/*.log
```

Never commit `.env`, `infra/asterisk/.ari_password`, or any other secret
(see `AGENTS.md` → Security).
