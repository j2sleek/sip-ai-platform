# Asterisk — telephony core

Configuration and lifecycle scripts for the Asterisk instance used by the SIP AI
Platform. Asterisk terminates SIP/RTP and exposes the ARI control interface to
`voice_core` and `control_api`.

## Layout

| Path | Purpose |
|---|---|
| `configure.sh` | Idempotent installer + configurator (installs Asterisk, renders `/etc/asterisk/*.conf`) |
| `start.sh` / `stop.sh` / `status.sh` | systemd-independent lifecycle helpers |
| `config/pjsip.conf` | PJSIP transport, endpoints (1001 Linphone, 2000 AI placeholder) |
| `config/extensions.conf` | Dialplan (`internal` context) |
| `config/ari.conf.template` | ARI user template (password injected at configure time) |
| `config/http.conf.template` | ARI HTTP listener template |

## Install & configure

```bash
bash infra/asterisk/configure.sh          # generate/reuse a local ARI password
ARI_PASSWORD=... bash infra/asterisk/configure.sh
```

`configure.sh`:

1. Installs the Asterisk package when it is missing (apt/dnf/yum/pacman/apk).
2. Copies `pjsip.conf` + `extensions.conf` into `${ASTERISK_ETC:-/etc/asterisk}`,
   backing up existing files to `*.pre-sip-ai.bak` once.
3. Renders `ari.conf` + `http.conf`, injecting the ARI password. The password
   comes from `$ARI_PASSWORD`, or is generated into `infra/asterisk/.ari_password`
   (git-ignored, `chmod 600`).
- Reloads Asterisk when it is already running.

## Lifecycle

```bash
./start.sh      # start (waits until the CLI answers); idempotent
./status.sh     # binary, version, process, CLI, module checks
./stop.sh       # stop the process tracked in the PID file
```

`start.sh` starts `asterisk -f` in the background and writes a PID file to
`/tmp/sip-ai-asterisk.pid`.

## Endpoints

| Extension | Purpose |
|---|---|
| `1001` | Linphone softphone (see [`LINPHONE_SETUP.md`](../../LINPHONE_SETUP.md)) |
| `1002` | Dialplan echo test |
| `2000` | AI service placeholder (hello-world + `Echo()`) |
| `3000` | DTMF test |
| `4000` | AudioSocket test → `127.0.0.1:9019` |

## Notes

- Secrets are never committed. `ari.conf`/`http.conf` are rendered at configure
  time from templates.
- The platform also works without Asterisk in `CALL_BACKEND=simulated` mode
  (used by the test suites and the voice-loop demo).
