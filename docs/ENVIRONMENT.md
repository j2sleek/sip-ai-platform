# Environment Report — Phase 0

_Generated: 2026-07-24. Read-only discovery. No software was installed, upgraded, or reconfigured._

This report documents the machine on which SIP AI Platform is currently being
bootstrapped. Re-run `scripts/doctor.sh` to refresh the live view.

## Classification legend

| Status | Meaning |
|---|---|
| **AVAILABLE** | Present and usable now. |
| **MISSING** | Not installed; required by a later phase; install deferred. |
| **INCOMPATIBLE** | Present but the version/build cannot satisfy the requirement. |
| **UNKNOWN** | Could not be determined in this environment. |
| **NEEDS VERIFICATION** | Present/plausible but must be confirmed before we depend on it. |

## Host overview

| Property | Value |
|---|---|
| OS | Ubuntu 26.04 LTS ("Resolute Raccoon") |
| Kernel | `6.17.0-PRoot-Distro` |
| Runtime environment | **Ubuntu guest running under PRoot-Distro inside Termux on Android** |
| Architecture | `aarch64` (ARM64) |
| CPU | ARM Cortex-A76 + Cortex-A55 (big.LITTLE), 8 cores, ~2.05 GHz max |
| RAM | 7.5 GiB total, ~2.8 GiB available at scan time, 6.0 GiB swap |
| Disk (/) | 228 GB volume, ~61 GB free (74% used) — shared with Android `/sdcard` |
| Shell | `/bin/bash` (bash) |

## Dependency matrix

| Dependency | Status | Detail |
|---|---|---|
| OS (Ubuntu) | AVAILABLE | Ubuntu 26.04 LTS |
| Architecture (ARM64) | AVAILABLE | `aarch64` — must be respected for all binaries/containers |
| CPU | AVAILABLE | 8-core Cortex-A76/A55; adequate for orchestration, weak for AI inference |
| RAM | AVAILABLE (constrained) | 7.5 GiB total; only ~2.8 GiB free during scan — a real constraint |
| Storage | AVAILABLE | ~61 GB free; enough for small models, not many large ones |
| Termux | AVAILABLE (dev only) | `/data/data/com.termux` present; PATH bridges into Termux |
| PRoot | PRESENT | Kernel tagged `PRoot-Distro` — no real init, syscall emulation overhead |
| Erlang/OTP | AVAILABLE | **OTP 29 / ERTS 17.0.3** (from Termux, `/data/data/com.termux/.../erl`) |
| Elixir | AVAILABLE | **1.20.2** (precompiled OTP-29 build) at `/opt/elixir` — installed in Phase 0.5 |
| Mix | AVAILABLE | **1.20.2** (ships with Elixir) at `/opt/elixir/bin/mix` |
| Node.js | AVAILABLE | v24.18.0 (via nvm, `/root/.nvm/...`) |
| npm | AVAILABLE | 11.16.0 |
| Python | AVAILABLE | Python 3.14.6 (Termux) |
| pip | AVAILABLE | pip 26.1.2 |
| Asterisk | MISSING | Not installed. Ubuntu apt candidate: **1:22.5.2** (Asterisk 22.x) |
| Docker | MISSING | Not installed; **not usable under PRoot** anyway (no daemon/cgroups) |
| systemd | INCOMPATIBLE | `systemctl` present but **not PID 1** — cannot manage services here |
| Git | AVAILABLE | git 2.55.0 |
| GPU | UNKNOWN / not usable | `/dev/dri/card0` (mobile GPU). No NVIDIA, no CUDA, no OpenCL/Vulkan tools |
| CUDA | MISSING | No `nvcc`, no NVIDIA driver |
| Build tools | AVAILABLE | clang 21.1.8, make, cmake, ffmpeg 8.1.2 (all via Termux) |

### Version-compatibility flags — RESOLVED in Phase 0.5

- **Erlang/OTP 29 vs Elixir**: RESOLVED. The Phase 0 concern was confirmed with
  authoritative evidence: the official Elixir compatibility table shows Elixir
  **1.18 supports only OTP 25–27** (so Ubuntu apt's 1.18.3 is **incompatible**
  with OTP 29), and **only Elixir 1.20 supports OTP 29** (range OTP 27–29). We
  installed **Elixir 1.20.2** (precompiled OTP-29 build) against the existing
  OTP 29. Verified: `elixir/iex/mix --version` all report
  "compiled with Erlang/OTP 29". See DECISIONS.md ADR-0006 and
  [`TOOLCHAIN.md`](TOOLCHAIN.md).
- **Mixed package origins**: `erl`, `python3`, `git`, `gcc`, `ffmpeg` resolve to
  Termux paths while `node`/`npm` come from nvm under the Ubuntu guest. This
  works but is fragile; the doctor prints the resolved path of each tool so the
  mix is visible.

## AI inference feasibility

| Factor | Finding |
|---|---|
| CPU | 8× ARM64 (A76/A55). Usable for tiny/quantized models only. |
| GPU acceleration | **None** — no CUDA/ROCm/Metal. Mobile GPU not usable for LLM/STT/TTS. |
| RAM headroom | ~2.8 GiB free. A 7B LLM (even 4-bit ≈ 4–5 GiB) will not fit comfortably. |
| Disk | ~61 GB free — fine for small models; avoid multi-GB model sprawl. |
| PRoot overhead | Syscall emulation adds latency; real-time audio inference is marginal. |

**Verdict: this device is a development/orchestration host, not an inference host.**
Local real-time STT+LLM+TTS on this machine is **not realistic** for production.

### Recommendations (zero-cost, local-first)

- **STT**: `faster-whisper` (CTranslate2) with `tiny`/`base` int8 models for dev
  smoke tests only. Expect non-real-time latency here. Plan to offload to a
  separate machine for production.
- **LLM**: For dev, a small quantized model via **Ollama** (e.g. `qwen2.5:1.5b`
  or `llama3.2:1b`, 4-bit) is the ceiling on this RAM budget. 7B+ models should
  run on a separate host. Keep the provider behind an interface so the endpoint
  can move.
- **TTS**: **Piper** (ONNX, CPU) is the best fit — small, fast, ARM64-friendly,
  fully offline. This is the one AI component likely to run acceptably here.
- **Architecture consequence**: keep STT/LLM/TTS behind provider interfaces
  (already mandated by AGENTS.md) so inference can move to a GPU host without
  touching the telephony/orchestration core. No large models downloaded in Phase 0.

## Asterisk media-transport feasibility

Asterisk is **not installed**, so all module-level facts below are **NEEDS
VERIFICATION** until Phase 2 installs it. The apt candidate is **Asterisk 22.x**
(`1:22.5.2`), which is a relevant baseline.

| Transport | Feasibility (projected) | Notes |
|---|---|---|
| ARI (call control) | AVAILABLE once installed | `res_ari` ships with 22.x. Primary control plane. |
| `chan_websocket` media | NEEDS VERIFICATION | Docs cite availability in 22.6.0+/23.0. The apt build is 22.5.2 — **likely too early**. Must confirm module presence in the actual build. |
| AudioSocket | NEEDS VERIFICATION (likely AVAILABLE) | Available since Asterisk 18; 22.x should include `app_audiosocket`/`res_audiosocket`. Strong fallback. |
| RTP External Media | NEEDS VERIFICATION (likely AVAILABLE) | ARI external media is broadly available; higher implementation cost. |
| PJSIP | NEEDS VERIFICATION (likely AVAILABLE) | `chan_pjsip` standard in 22.x. |

**Networking caveat (PRoot/Termux):** UDP/RTP behaviour and privileged ports
under PRoot are unreliable. SIP/RTP and AudioSocket (TCP) should be validated
carefully in Phase 2; a native Ubuntu VPS is the intended production target.

## Environment constraints that shape the project

1. **ARM64 everywhere** — no x86_64 assumptions; verify every binary/image is `arm64`.
2. **No Docker, no systemd-as-init** — Phase 0–4 must run processes directly
   (foreground/`nohup`/tmux). Container and systemd deployment belong to the
   Ubuntu VPS production target (Phase 13).
3. **Constrained RAM + no GPU** — heavy AI inference is offloaded, not local.
4. **PRoot overhead** — treat measured latencies here as pessimistic; real
   numbers come from the production VPS.
5. **Mixed Termux/Ubuntu toolchain** — pin a single Elixir/OTP toolchain before Phase 1.
