# Toolchain

Reproducible development toolchain for SIP AI Platform, established in
Phase 0.5. See [`DECISIONS.md`](DECISIONS.md) ADR-0006 for the rationale.

## Pinned versions

| Component | Version | Required | Status |
|---|---|---|---|
| OS | Ubuntu 26.04 LTS | Ubuntu 22.04+ (Linux) | AVAILABLE |
| Architecture | `aarch64` (ARM64) | ARM64 or x86_64 | AVAILABLE |
| Erlang/OTP | **29** (ERTS 17.0.3) | OTP 27–29 | AVAILABLE |
| Elixir | **1.20.2** (compiled with OTP 29) | 1.20.x (only branch supporting OTP 29) | AVAILABLE |
| Mix | **1.20.2** (ships with Elixir) | matches Elixir | AVAILABLE |
| Node.js | **24.18.0** | ≥ 20.11 | AVAILABLE |
| Python | **3.14.6** | ≥ 3.11 | AVAILABLE |

The machine-readable pin lives in [`/.tool-versions`](../.tool-versions) at the
repository root (asdf/mise-compatible; declarative only — neither tool needs to
be installed to read it).

## Compatibility basis

Elixir↔OTP compatibility is defined by the official Elixir compatibility table.
**Only Elixir 1.20 supports Erlang/OTP 29** (its supported range is OTP 27–29).
Elixir 1.18 (the Ubuntu apt candidate) supports only OTP 25–27 and is therefore
**incompatible** with the installed OTP 29.

- Source: <https://hexdocs.pm/elixir/compatibility-and-deprecations.html>
- Elixir 1.20.2 release assets (incl. `elixir-otp-29.zip`):
  <https://github.com/elixir-lang/elixir/releases/tag/v1.20.2>

## Installation method

Elixir was installed from the **official precompiled release**
`elixir-otp-29.zip` (Elixir 1.20.2, built against OTP 29), extracted to
`/opt/elixir`. Precompiled Elixir is BEAM bytecode plus shell scripts and is
**architecture-independent**, so it runs on ARM64/PRoot without compilation and
reuses the existing OTP 29. No root-owned system packages were changed; no
toolchain manager (asdf/mise) was required.

`PATH` is persisted via `/etc/profile.d/elixir.sh` and `/root/.bashrc`
(`export PATH="/opt/elixir/bin:$PATH"`).

## Reproducing this toolchain

On this machine, Erlang/OTP 29 is already present (from Termux). To reproduce
Elixir on any ARM64/x86_64 Linux that already has OTP 29:

```sh
# 1. Confirm OTP 29 is present
erl -noshell -eval 'io:format("OTP ~s~n",[erlang:system_info(otp_release)]), halt().'

# 2. Download the precompiled Elixir 1.20.2 built for OTP 29
cd /tmp
curl -fsSL -o elixir-otp-29.zip \
  https://github.com/elixir-lang/elixir/releases/download/v1.20.2/elixir-otp-29.zip
curl -fsSL -o elixir-otp-29.zip.sha256sum \
  https://github.com/elixir-lang/elixir/releases/download/v1.20.2/elixir-otp-29.zip.sha256sum

# 3. Verify checksum (expected: a9e88cd41fbbba7da6f6dc237a49dd2ed4e70457121035cc7fc56ad05582f394)
sha256sum -c elixir-otp-29.zip.sha256sum

# 4. Install to /opt/elixir and put it on PATH
mkdir -p /opt/elixir && unzip -q elixir-otp-29.zip -d /opt/elixir
export PATH="/opt/elixir/bin:$PATH"
```

If OTP 29 is **not** present on the target machine, install Erlang/OTP 29 first
(e.g. via the OS package that provides OTP 29, or `asdf install erlang 29.0`),
then use the matching `elixir-otp-29.zip`.

## Verification commands

```sh
elixir --version        # => Elixir 1.20.2 (compiled with Erlang/OTP 29)
iex --version           # => IEx 1.20.2 (compiled with Erlang/OTP 29)
mix --version           # => Mix 1.20.2 (compiled with Erlang/OTP 29)
elixir -e 'IO.puts("Elixir OK")'

# Build + test the bootstrap application
cd apps/voice_core
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix run -e 'IO.inspect(VoiceCore.health())'   # => :ok
```

Or simply run the environment doctor from the repo root:

```sh
sh scripts/doctor.sh
```

## Known Termux/PRoot limitations

- Erlang/OTP 29 comes from Termux (`/data/data/com.termux/files/usr/lib/erlang`)
  and is reached from the Ubuntu guest via `PATH`. This is functional but the
  toolchain is split across Termux and the Ubuntu guest — keep the pin honest.
- The precompiled Elixir sidesteps ARM64/PRoot build issues entirely (no native
  compilation), which is exactly why this method was chosen.
- Production (Ubuntu VPS) should install OTP 29 + Elixir 1.20.2 natively from a
  single source; this pin transfers directly.
