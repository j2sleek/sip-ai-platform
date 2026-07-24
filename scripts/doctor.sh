#!/bin/sh
# SIP AI Platform — Environment Doctor
#
# Phase 0 diagnostic. Inspects the host and reports whether the tooling needed
# by the platform is present. It is intentionally conservative:
#
#   - POSIX sh; no bashisms required.
#   - Never installs, upgrades, or modifies anything.
#   - Never requires root.
#   - Degrades gracefully when a command or file is missing.
#   - Exits non-zero ONLY when a CRITICAL check fails (see CRITICAL_MISSING).
#
# Works on Ubuntu and, as far as practical, on Termux / PRoot.

# Intentionally NOT using `set -e`: we want to run every check even when
# individual probes fail.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="$(printf '\033[0m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"
  C_BLUE="$(printf '\033[34m')"
  C_BOLD="$(printf '\033[1m')"
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_BOLD=""
fi

WARN_COUNT=0
CRIT_COUNT=0

section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"
}

# status LABEL STATE DETAIL
# STATE is one of: OK WARN CRIT INFO
status() {
  _label="$1"; _state="$2"; _detail="$3"
  case "$_state" in
    OK)   _tag="${C_GREEN}[ AVAILABLE ]${C_RESET}" ;;
    WARN) _tag="${C_YELLOW}[  MISSING  ]${C_RESET}"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
    CRIT) _tag="${C_RED}[ CRITICAL ]${C_RESET}"; CRIT_COUNT=$((CRIT_COUNT + 1)) ;;
    INFO) _tag="${C_BLUE}[   INFO   ]${C_RESET}" ;;
    *)    _tag="[    ??    ]" ;;
  esac
  printf '  %s %-22s %s\n' "$_tag" "$_label" "$_detail"
}

have() { command -v "$1" >/dev/null 2>&1; }

# first line of a command's output, guarded
firstline() { "$@" 2>/dev/null | head -n 1; }

# ---------------------------------------------------------------------------
# CRITICAL runtimes: absence fails the doctor (exit non-zero).
# These are what the platform's core (Elixir orchestration + tooling) needs
# to even begin Phase 1. Adjust as the project matures.
# ---------------------------------------------------------------------------
# git is the only hard requirement for Phase 0 repo work. Elixir/Erlang are
# required for Phase 1+, so they are treated as CRITICAL here to surface the
# gap loudly, but see NOTE at the bottom about running the doctor pre-install.
CRITICAL_LIST="git"

printf '%s SIP AI Platform — Environment Doctor %s\n' "$C_BOLD" "$C_RESET"
printf 'Read-only diagnostic. No software will be installed or changed.\n'

# ---------------------------------------------------------------------------
section "Operating System"
# ---------------------------------------------------------------------------
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  status "OS" INFO "${PRETTY_NAME:-$NAME $VERSION_ID}"
else
  status "OS" INFO "$(uname -s) (no /etc/os-release)"
fi
status "Kernel" INFO "$(uname -r 2>/dev/null || echo unknown)"

# Termux / PRoot detection
TERMUX="no"
if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ] || \
   [ -n "${PREFIX##*/com.termux/*}" ] 2>/dev/null; then
  [ -d /data/data/com.termux ] && TERMUX="yes"
fi
case "$(uname -r 2>/dev/null)" in
  *PRoot*|*proot*) PROOT="yes" ;;
  *) PROOT="no" ;;
esac
status "Termux filesystem" INFO "$TERMUX"
status "PRoot kernel" INFO "$PROOT"

# ---------------------------------------------------------------------------
section "Hardware"
# ---------------------------------------------------------------------------
status "Architecture" INFO "$(uname -m 2>/dev/null || echo unknown)"

# CPU model (try several sources)
CPU_MODEL="unknown"
if have lscpu; then
  CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2}' | paste -sd '/' - 2>/dev/null)"
fi
if [ -z "$CPU_MODEL" ] || [ "$CPU_MODEL" = "unknown" ]; then
  if [ -r /proc/cpuinfo ]; then
    CPU_MODEL="$(awk -F: '/model name|Hardware/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"
    [ -z "$CPU_MODEL" ] && CPU_MODEL="$(uname -p 2>/dev/null)"
  fi
fi
CORES="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo '?')"
status "CPU" INFO "${CPU_MODEL:-unknown} (${CORES} cores)"

# RAM
if [ -r /proc/meminfo ]; then
  MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  MEM_AVAIL_KB="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
  MEM_GB="$(awk "BEGIN{printf \"%.1f\", ${MEM_KB:-0}/1024/1024}")"
  MEM_AV_GB="$(awk "BEGIN{printf \"%.1f\", ${MEM_AVAIL_KB:-0}/1024/1024}")"
  status "RAM" INFO "${MEM_GB} GiB total, ${MEM_AV_GB} GiB available"
else
  status "RAM" INFO "unknown (/proc/meminfo unreadable)"
fi

# Disk (root filesystem)
if have df; then
  DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"
  status "Disk (/)" INFO "${DISK:-unknown}"
else
  status "Disk (/)" INFO "unknown (df unavailable)"
fi

# GPU (informational only)
GPU="none detected"
if have nvidia-smi; then
  GPU="NVIDIA: $(firstline nvidia-smi --query-gpu=name --format=csv,noheader)"
elif [ -e /dev/dri/card0 ]; then
  GPU="DRI render node present (/dev/dri/card0) — likely mobile/integrated GPU, no CUDA"
fi
status "GPU" INFO "$GPU"

# ---------------------------------------------------------------------------
section "Init / Container tooling (informational)"
# ---------------------------------------------------------------------------
if [ -d /run/systemd/system ]; then
  status "systemd" INFO "running as init"
elif have systemctl; then
  status "systemd" INFO "systemctl present but NOT PID 1 (services won't manage via systemd)"
else
  status "systemd" INFO "not available"
fi

if have docker; then
  status "Docker" INFO "$(firstline docker --version)"
else
  status "Docker" INFO "not available"
fi

# ---------------------------------------------------------------------------
section "Runtimes & Tools"
# ---------------------------------------------------------------------------

# check_tool LABEL COMMAND VERSION_ARGS...
check_tool() {
  _label="$1"; _cmd="$2"; shift 2
  if have "$_cmd"; then
    _ver="$("$_cmd" "$@" 2>&1 | head -n 1)"
    status "$_label" OK "${_ver:-present} [$(command -v "$_cmd")]"
    return 0
  fi
  # decide severity
  for _c in $CRITICAL_LIST; do
    if [ "$_c" = "$_cmd" ]; then
      status "$_label" CRIT "not found (required)"
      return 1
    fi
  done
  status "$_label" WARN "not found"
  return 1
}

# Elixir stack
check_tool "Elixir"       elixir  --version
check_tool "Erlang (erl)" erl     -noshell -eval 'io:fwrite("Erlang/OTP ~s (erts ~s)~n",[erlang:system_info(otp_release), erlang:system_info(version)]), halt().'
check_tool "Mix"          mix     --version

# Node stack
check_tool "Node.js" node --version
check_tool "npm"     npm  --version

# Python stack
check_tool "Python 3" python3 --version
check_tool "pip3"     pip3    --version

# Telephony
check_tool "Asterisk" asterisk -V

# VCS
check_tool "Git" git --version

# ---------------------------------------------------------------------------
section "Asterisk capabilities"
# ---------------------------------------------------------------------------
if have asterisk; then
  # If asterisk is installed we probe module availability WITHOUT changing config.
  # `asterisk -rx` requires a running instance; guard it.
  if asterisk -rx "core show version" >/dev/null 2>&1; then
    status "Asterisk running" OK "$(firstline asterisk -rx 'core show version')"
    for mod in res_ari.so chan_pjsip.so app_audiosocket.so res_audiosocket.so chan_websocket.so; do
      if asterisk -rx "module show like $mod" 2>/dev/null | grep -q "$mod"; then
        status "  $mod" OK "loaded"
      else
        status "  $mod" WARN "not loaded / not present"
      fi
    done
  else
    status "Asterisk running" WARN "binary present but not running (cannot query modules)"
  fi
else
  status "Asterisk" WARN "not installed — media/telephony checks deferred to Phase 2"
fi

# ---------------------------------------------------------------------------
section "Elixir / OTP compatibility"
# ---------------------------------------------------------------------------
# Verifies that the detected Elixir minor version supports the detected OTP
# release, using the official Elixir compatibility table. Never reports a false
# positive: unknown combinations => MANUAL VERIFICATION REQUIRED.
#
# Table (Elixir minor -> supported OTP range), from:
#   https://hexdocs.pm/elixir/compatibility-and-deprecations.html
#   1.20 -> 27-29   1.19 -> 26-28   1.18 -> 25-27   1.17 -> 25-27
#   1.16 -> 24-26   1.15 -> 24-26
otp_supported_range() { # $1 = "MAJOR.MINOR" -> echoes "MIN MAX" or nothing
  case "$1" in
    1.20) echo "27 29" ;;
    1.19) echo "26 28" ;;
    1.18) echo "25 27" ;;
    1.17) echo "25 27" ;;
    1.16) echo "24 26" ;;
    1.15) echo "24 26" ;;
    *) echo "" ;;
  esac
}

if have elixir && have erl; then
  OTP_REL="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().' 2>/dev/null)"
  # `elixir --version` prints a line like: "Elixir 1.20.2 (compiled with Erlang/OTP 29)"
  ELIXIR_FULL="$(elixir --version 2>/dev/null | awk '/^Elixir /{print $2; exit}')"
  ELIXIR_MM="$(printf '%s' "$ELIXIR_FULL" | awk -F. '{print $1"."$2}')"
  status "Detected OTP" INFO "${OTP_REL:-unknown}"
  status "Detected Elixir" INFO "${ELIXIR_FULL:-unknown} (minor ${ELIXIR_MM:-?})"

  RANGE="$(otp_supported_range "$ELIXIR_MM")"
  if [ -n "$RANGE" ] && [ -n "$OTP_REL" ] && printf '%s' "$OTP_REL" | grep -Eq '^[0-9]+$'; then
    RMIN="${RANGE% *}"; RMAX="${RANGE#* }"
    if [ "$OTP_REL" -ge "$RMIN" ] && [ "$OTP_REL" -le "$RMAX" ]; then
      status "Compatibility" OK "Elixir $ELIXIR_MM supports OTP $RMIN-$RMAX; OTP $OTP_REL is COMPATIBLE"
    else
      status "Compatibility" CRIT "Elixir $ELIXIR_MM supports OTP $RMIN-$RMAX; OTP $OTP_REL is OUTSIDE that range"
    fi
  else
    status "Compatibility" WARN "MANUAL VERIFICATION REQUIRED (Elixir $ELIXIR_MM / OTP $OTP_REL not in built-in table)"
  fi
else
  status "Compatibility" INFO "Elixir and/or Erlang missing — cannot check (see Runtimes above)"
fi

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------
printf '  %sWarnings (missing/optional): %s%s\n' "$C_YELLOW" "$WARN_COUNT" "$C_RESET"
printf '  %sCritical failures:           %s%s\n' "$C_RED" "$CRIT_COUNT" "$C_RESET"

if [ "$CRIT_COUNT" -gt 0 ]; then
  printf '\n%sDoctor result: CRITICAL prerequisites missing.%s\n' "$C_RED" "$C_RESET"
  exit 1
fi

printf '\n%sDoctor result: no critical failures.%s\n' "$C_GREEN" "$C_RESET"
printf 'Note: MISSING items above are expected in Phase 0 and are installed in later phases.\n'
exit 0
