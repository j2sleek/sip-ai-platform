#!/usr/bin/env bash
#
# Idempotent Asterisk installer + configurator for the SIP AI Platform.
#
# What it does:
#   1. Installs the Asterisk package when missing (distro-aware, best effort).
#   2. Installs the platform's PJSIP + dialplan config into $ASTERISK_ETC,
#      backing up any pre-existing files once (*.pre-sip-ai.bak).
#   3. Renders ari.conf + http.conf, injecting the ARI password.
#   4. Reloads Asterisk if it is already running.
#
# Secrets are NEVER committed. If $ARI_PASSWORD is unset a strong password is
# generated and stored in infra/asterisk/.ari_password (git-ignored, chmod 600).
# See AGENTS.md -> Security.
#
# Usage:
#   ./configure.sh                        # generate/reuse a local ARI password
#   ARI_PASSWORD=... ./configure.sh       # use an explicit password
#   ARI_USERNAME=myuser ./configure.sh    # override the ARI username
#   SKIP_ASTERISK_INSTALL=1 ./configure.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
ASTERISK_ETC="${ASTERISK_ETC:-/etc/asterisk}"

ARI_USER="${ARI_USERNAME:-voice_core}"
ARI_APP="${ARI_APP_NAME:-voice_core}"
HTTP_BINDADDR="${ASTERISK_HTTP_BINDADDR:-0.0.0.0}"
HTTP_BINDPORT="${ASTERISK_HTTP_BINDPORT:-8088}"

SECRET_FILE="${ARI_PASSWORD_FILE:-$SCRIPT_DIR/.ari_password}"

log() { printf '[asterisk-configure] %s\n' "$*"; }
die() { printf '[asterisk-configure] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    fi
    die "root privileges are required to write $ASTERISK_ETC"
  fi
}

ensure_asterisk() {
  if command -v asterisk >/dev/null 2>&1; then
    log "asterisk present: $(asterisk -V 2>/dev/null || echo unknown)"
    return
  fi
  if [ "${SKIP_ASTERISK_INSTALL:-0}" = "1" ]; then
    die "asterisk is not installed and SKIP_ASTERISK_INSTALL=1"
  fi
  log "asterisk not found — installing via the system package manager"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y asterisk
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y asterisk
  elif command -v yum >/dev/null 2>&1; then
    yum install -y asterisk
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm asterisk
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache asterisk
  else
    die "no supported package manager found; install Asterisk manually"
  fi
  command -v asterisk >/dev/null 2>&1 || die "Asterisk installation produced no binary"
}

resolve_password() {
  if [ -n "${ARI_PASSWORD:-}" ]; then
    log "using ARI password from the environment"
    return
  fi
  if [ -f "$SECRET_FILE" ]; then
    ARI_PASSWORD="$(cat "$SECRET_FILE")"
    log "reusing generated ARI password from $SECRET_FILE"
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    ARI_PASSWORD="$(openssl rand -hex 24)"
  else
    ARI_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  umask 077
  printf '%s' "$ARI_PASSWORD" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  log "generated a new ARI password -> $SECRET_FILE (keep this file secret)"
}

render() {
  local src="$1" dst="$2"
  [ -f "$src" ] || die "missing template $src"
  sed \
    -e "s|@ARI_USER@|${ARI_USER}|g" \
    -e "s|@ARI_APP@|${ARI_APP}|g" \
    -e "s|@ARI_PASSWORD@|${ARI_PASSWORD}|g" \
    -e "s|@HTTP_BINDADDR@|${HTTP_BINDADDR}|g" \
    -e "s|@HTTP_BINDPORT@|${HTTP_BINDPORT}|g" \
    "$src" > "$dst"
  chmod 640 "$dst"
  log "rendered $dst"
}

install_config() {
  mkdir -p "$ASTERISK_ETC"

  # Static configs (PJSIP endpoints, dialplan).
  local f src dst
  for f in pjsip.conf extensions.conf; do
    src="$CONFIG_DIR/$f"
    dst="$ASTERISK_ETC/$f"
    [ -f "$src" ] || continue
    if [ -f "$dst" ] && [ ! -f "$dst.pre-sip-ai.bak" ]; then
      cp -p "$dst" "$dst.pre-sip-ai.bak"
      log "backed up existing $dst -> $dst.pre-sip-ai.bak"
    fi
    install -m 640 "$src" "$dst"
    log "installed $dst"
  done

  # Rendered configs (secrets injected here).
  render "$CONFIG_DIR/ari.conf.template" "$ASTERISK_ETC/ari.conf"
  render "$CONFIG_DIR/http.conf.template" "$ASTERISK_ETC/http.conf"
}

fix_ownership() {
  if id asterisk >/dev/null 2>&1; then
    chown asterisk:asterisk \
      "$ASTERISK_ETC/pjsip.conf" \
      "$ASTERISK_ETC/extensions.conf" \
      "$ASTERISK_ETC/ari.conf" \
      "$ASTERISK_ETC/http.conf" 2>/dev/null || true
  fi
}

reload_if_running() {
  if asterisk -rx "core show version" >/dev/null 2>&1; then
    log "reloading running Asterisk"
    asterisk -rx "module reload res_pjsip.so" >/dev/null 2>&1 || true
    asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
    asterisk -rx "module reload res_ari.so" >/dev/null 2>&1 || true
    asterisk -rx "http reload" >/dev/null 2>&1 || true
  fi
}

summary() {
  cat <<EOF
[asterisk-configure] done.
  ARI user     : $ARI_USER
  ARI app      : $ARI_APP
  ARI endpoint : http://127.0.0.1:$HTTP_BINDPORT/ari
  Config dir   : $ASTERISK_ETC
  Secret file  : $SECRET_FILE (git-ignored)

Next:
  infra/asterisk/start.sh        # start Asterisk (idempotent)
  start_production.sh            # start the full platform
EOF
}

main() {
  require_root "$@"
  ensure_asterisk
  resolve_password
  install_config
  fix_ownership
  reload_if_running
  summary
}

main "$@"
