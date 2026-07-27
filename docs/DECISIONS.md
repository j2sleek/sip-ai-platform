# Decision Record

Architecture Decision Records (ADRs) for SIP AI Platform. Newest decisions are
appended. Phase 0 decisions are intentionally **reversible** — where evidence is
incomplete, the decision is recorded as *provisional* and gated on verification.

---

## ADR-0001 — Adopt the documented layered architecture

**Status:** Accepted

**Context:** The project ships architecture docs (`ARCHITECTURE.md`,
`MEDIA-STREAMING-DECISION.md`, `PLAN.md`, `AGENTS.md`, specs). Phase 0 validates
their assumptions against the real environment.

**Decision:** Keep the documented separation of concerns:

- **Asterisk** — SIP/PJSIP, dial plan, call setup/teardown, RTP. No AI logic.
- **Elixir/OTP** — ARI call control, per-call supervised sessions, media
  coordination, agent + tool orchestration, Control API, observability.
- **Python** — STT / LLM adapters / TTS behind stable HTTP APIs. No SIP state.
- **Node.js/TypeScript** — existing ChartCapture API and integrations.
- **n8n** — business automation, outside the real-time call loop.
- **Supabase/PostgreSQL** — persistence where required.

**Consequence:** Media transport stays behind a `MediaTransport` abstraction;
STT/LLM/TTS stay behind provider interfaces. No changes to this in Phase 0.

---

## ADR-0002 — Proposed Asterisk baseline: 22.x (provisional)

**Status:** Provisional — needs verification in Phase 2

**Context:** Asterisk is not installed. The Ubuntu 26.04 apt candidate is
`1:22.5.2` (Asterisk **22.x**). The media-streaming doc targets `chan_websocket`,
which its cited docs place in **22.6.0+ / 23.0** release lines.

**Decision:** Propose **Asterisk 22.x** as the baseline, because it is the
distro-supported, zero-cost path on this ARM64 Ubuntu and includes ARI, PJSIP,
and AudioSocket. Do **not** commit to a build that guarantees `chan_websocket`
until we confirm the exact version and module list.

**Open question:** The apt build (22.5.2) is *earlier* than the 22.6.0 where
`chan_websocket` is documented. If `chan_websocket` is required from day one, we
may need a newer point release or a source build — deferred, not decided.

---

## ADR-0003 — Media transport ordering (provisional)

**Status:** Provisional — POC required (Phase 4)

**Context:** Preferred order per `MEDIA-STREAMING-DECISION.md`:
`chan_websocket` → AudioSocket → RTP External Media. Actual module availability
is unverified because Asterisk is not installed.

**Decision (provisional):**

- **Recommended first media transport: AudioSocket.**
  Rationale: available since Asterisk 18 and almost certainly present in the
  22.x apt build; TCP-based (simpler than raw RTP under PRoot); low Elixir
  implementation cost; excellent debuggability. It lets Phase 4 proceed without
  depending on an unverified `chan_websocket` build.
- **Target/preferred transport: `chan_websocket`.**
  Remains the strategic target per the architecture, adopted once we run on an
  Asterisk build that ships and loads `chan_websocket.so` (22.6.0+/23.x). At
  that point WebSocket becomes primary and AudioSocket the fallback.
- **Fallback: RTP External Media.**
  Interop only, when neither of the above suffices.

**Why the order differs from the doc for _now_:** The document's preferred
order assumes a build with `chan_websocket`. Our concrete, installable baseline
(22.5.2) predates it. Rather than block on a source build, Phase 4 starts on
AudioSocket and promotes WebSocket to primary once verified. This keeps the
`MediaTransport` abstraction honest — the ordering is a deployment fact, not an
architectural one.

**Reversal trigger:** Confirming a running Asterisk with `chan_websocket.so`
loaded flips the primary transport to WebSocket with no architectural change.

---

## ADR-0004 — Toolchain: pin a single Elixir/OTP pairing before Phase 1

**Status:** Accepted (action deferred to Phase 1)

**Context:** Installed Erlang is **OTP 29** (from Termux). Elixir is **absent**;
Ubuntu apt offers Elixir **1.18.3**. Elixir 1.18 does not officially support
OTP 29, and the toolchain is split across Termux and the Ubuntu guest.

**Decision:** Before writing any Elixir, install a **single, consistent,
supported Elixir + OTP pairing** in the Ubuntu guest (candidate: `asdf` with a
matching pair, e.g. Elixir 1.18.x on OTP 27, or a newer Elixir that supports OTP
29). Do **not** mix Termux OTP 29 with an Ubuntu apt Elixir 1.18.

**Consequence:** Phase 1 begins with a documented, reproducible `.tool-versions`.
No install performed in Phase 0.

---

## ADR-0005 — Deployment substrate: direct processes in dev, VPS in prod

**Status:** Accepted

**Context:** No Docker; `systemd` is not PID 1 under PRoot. GPU/CUDA absent;
RAM constrained.

**Decision:**

- Development (this device): run components as **direct foreground/background
  processes** (no Docker, no systemd units). Document Termux/PRoot limitations.
- Production: **Ubuntu VPS** with OTP release, systemd or containers, Caddy,
  firewall, PostgreSQL/Supabase — per `PLAN.md` Phase 13.
- **AI inference is offloaded**: STT/LLM/TTS run behind provider interfaces so
  they can move to a GPU-capable host without touching telephony/orchestration.

**Consequence:** No container/systemd work in early phases. Providers must be
endpoint-configurable via environment variables.

---

## ADR-0006 — Elixir/OTP toolchain

**Status:** Accepted (implemented in Phase 0.5)

**Context:** The system has Erlang/**OTP 29** (from Termux) and no Elixir. ADR-0004
flagged that a consistent, supported Elixir/OTP pairing had to be chosen before
writing Elixir. The Phase 0 guess (Elixir 1.18) needed verification.

**Evidence (authoritative):** The official Elixir compatibility table
(<https://hexdocs.pm/elixir/compatibility-and-deprecations.html>) maps Elixir
minor versions to supported OTP ranges:

- Elixir **1.20 → OTP 27–29** ✅ (only branch that supports OTP 29)
- Elixir 1.19 → OTP 26–28
- Elixir **1.18 → OTP 25–27** ❌ (does **not** support OTP 29 — rules out apt's 1.18.3)

Latest stable is **Elixir 1.20.2**, and its GitHub release ships a precompiled
`elixir-otp-29.zip` asset (<https://github.com/elixir-lang/elixir/releases/tag/v1.20.2>).

**Decision:**

1. **Elixir version: 1.20.2** — the only release line compatible with the
   installed OTP 29, and the current stable branch.
2. **Keep the existing OTP 29** — no OTP change was needed (satisfies ADR-0004's
   "don't upgrade OTP blindly"). Elixir 1.20 was chosen to fit OTP, not the reverse.
3. **Install method: official precompiled release** (`elixir-otp-29.zip`)
   extracted to `/opt/elixir`, added to `PATH` via `/etc/profile.d/elixir.sh`
   and `/root/.bashrc`.

**Why precompiled over the alternatives:**

- **apt (Ubuntu):** offers Elixir 1.18.3 → **incompatible** with OTP 29. Rejected.
- **Erlang Solutions repo:** would install its own OTP; risks displacing OTP 29
  and uncertain ARM64 story. Rejected.
- **asdf / mise:** not installed; would require compiling Elixir (and possibly
  Erlang) from source under PRoot — slow and fragile. Rejected for Phase 0.5.
- **Build from source:** unnecessary; the precompiled artifact is BEAM bytecode
  and shell scripts. Rejected.
- **Precompiled release (chosen):** architecture-independent (runs on ARM64/PRoot
  with no compilation), reuses OTP 29, no root-owned system packages changed,
  trivially version-pinned. Simplest reliable option.

**Reproduction:** `.tool-versions` at the repo root pins
`elixir 1.20.2-otp-29` / `erlang 29.0`; full steps and checksum in
[`TOOLCHAIN.md`](TOOLCHAIN.md).

**Verification:** `elixir/iex/mix --version` all report
"compiled with Erlang/OTP 29"; `mix compile --warnings-as-errors`, `mix test`
(2 passed), and `mix format --check-formatted` all pass on the `voice_core`
bootstrap app.

**Known Termux/PRoot limitations:** OTP 29 lives in the Termux tree
(`/data/data/com.termux/files/usr/lib/erlang`) and is reached from the Ubuntu
guest via `PATH`; the toolchain is split across Termux and the guest. The
precompiled Elixir avoids native-build issues. Production (Ubuntu VPS) should
install OTP 29 + Elixir 1.20.2 natively from one source; the pin transfers directly.

---

## Blockers

| # | Blocker | Severity | Resolution path |
|---|---|---|---|
| B1 | Asterisk not installed → media/module facts unverified | High (blocks Phase 2+) | Phase 2: install Asterisk 22.x, capture `module show` output |
| B2 | `chan_websocket` availability unconfirmed; apt build (22.5.2) predates documented 22.6.0 | Medium | Verify in Phase 2; use AudioSocket first (ADR-0003) |
| B3 | ~~Elixir/Mix missing + OTP 29 vs Elixir 1.18 mismatch~~ | ~~High~~ | **RESOLVED (Phase 0.5, ADR-0006):** installed Elixir 1.20.2 (OTP-29 precompiled build); compatibility verified |
| B4 | No GPU/CUDA + constrained RAM → local heavy inference infeasible | Medium | Offload inference; dev uses tiny models (Piper/faster-whisper-tiny/small Ollama) |
| B5 | PRoot/Termux: no Docker, systemd not init, UDP/RTP reliability uncertain | Medium | Direct processes in dev; validate SIP/RTP in Phase 2; production on VPS |


---

## ADR-0007 — Asterisk Runtime Strategy

**Status:** Accepted (implemented in Phase 2A)

**Context:** Asterisk is now installed in an Ubuntu 26.04/PRoot/Termux environment. The system has no systemd as PID 1, and process management must be handled manually. The installed version is Asterisk 22.5.2 from the Ubuntu apt repository.

**Decision:**

1. **Installation method:** Use Ubuntu 26.04 apt repository package (`asterisk` 1:22.5.2~dfsg+~cs6.15.60671435-1). This provides a stable, supported baseline without requiring source compilation.

2. **Process management:** Since systemd is not available as PID 1 under PRoot, implement custom start/stop/status scripts in `infra/asterisk/` that:
   - Start Asterisk in foreground mode (`asterisk -f`)
   - Use PID files for tracking (`/tmp/sip-ai-asterisk.pid`)
   - Avoid `killall` or `pkill` (target specific PID only)
   - Support graceful shutdown (SIGTERM)

3. **Development vs Production:**
   - Development (this environment): Use custom scripts for lifecycle management
   - Production (Ubuntu VPS): Use systemd service files and proper user permissions

**Why apt package over source compilation:**

- Zero-cost, no compilation time
- Supported by Ubuntu/Debian
- ARM64-compatible
- Includes all standard modules
- Easier security updates

**Known limitations:**

- Asterisk 22.5.2 does not include `chan_websocket.so` (requires 22.6.0+)
- PRoot may affect UDP/RTP performance
- No privileged port binding without root

**Reproduction:** Installation via `apt install asterisk` on Ubuntu 26.04 ARM64.

---

## ADR-0008 — Media Transport Capability Assessment

**Status:** Accepted (implemented in Phase 2A)

**Context:** Phase 2A installed Asterisk 22.5.2 and verified module availability. The key question was whether `chan_websocket` (the preferred transport per MEDIA-STREAMING-DECISION.md) is available in the apt package.

**Evidence:**

- `chan_websocket.so`: **NOT PRESENT** in Asterisk 22.5.2
- `app_audiosocket.so`: ✅ Present and loaded
- `chan_audiosocket.so`: ✅ Present and loaded  
- `res_audiosocket.so`: ✅ Present and loaded
- RTP modules: ✅ All present and loaded

**Decision:**

1. **Primary media transport for Phase 4:** AudioSocket
   - All required modules are available
   - TCP-based (simpler than UDP/RTP under PRoot)
   - Lower implementation complexity
   - Excellent debuggability

2. **chan_websocket status:** Deferred
   - Not available in current build
   - Do NOT attempt source compilation at this time
   - Architecture remains open for future adoption
   - `MediaTransport` abstraction keeps door open

3. **Secondary transport:** RTP External Media
   - Available as fallback
   - Useful for interoperability
   - Higher complexity (UDP packet timing)

**Why AudioSocket first:**

- Verified availability in the installed build
- Matches ADR-0003 provisional decision
- Lower risk for initial implementation
- TCP protocol works reliably under PRoot
- Simpler Elixir implementation

**Future chan_websocket adoption path:**

1. Wait until Ubuntu provides Asterisk 22.6.0+ or 23.x in apt
2. OR deploy to Ubuntu VPS with newer Asterisk version
3. OR build from source when there's a demonstrated need
4. Implement as additional `MediaTransport` adapter
5. Benchmark against AudioSocket before switching

**Reversal trigger:** Confirming `chan_websocket.so` in a production-deployable build.

---

## Blockers Update

| # | Blocker | Severity | Resolution path |
|---|---------|----------|------------|
| B1 | Asterisk not installed → media/module facts unverified | High (blocks Phase 2+) | **RESOLVED (Phase 2A):** Asterisk 22.5.2 installed; modules verified via `module show` |
| B2 | `chan_websocket` availability unconfirmed; apt build (22.5.2) predates documented 22.6.0 | Medium | **RESOLVED (Phase 2A):** Confirmed NOT present; AudioSocket selected as primary transport |
| B3 | ~~Elixir/Mix missing + OTP 29 vs Elixir 1.18 mismatch~~ | ~~High~~ | **RESOLVED (Phase 0.5, ADR-0006):** installed Elixir 1.20.2 (OTP-29 precompiled build); compatibility verified |
| B4 | No GPU/CUDA + constrained RAM → local heavy inference infeasible | Medium | Offload inference; dev uses tiny models (Piper/faster-whisper-tiny/small Ollama) |
| B5 | PRoot/Termux: no Docker, systemd not init, UDP/RTP reliability uncertain | Medium | Direct processes in dev (ADR-0007); validate SIP/RTP in Phase 2B; production on VPS |


---

## ADR-0009 — PJSIP Telephony Foundation

**Status:** Accepted (implemented in Phase 2B)

**Context:** Phase 2B requires configuring Asterisk to support Linphone registration and basic call testing. The platform needs a reproducible telephony foundation before integrating Elixir ARI control.

**Decision:**

1. **Endpoint 1001**: Represents the Linphone client
   - Standard SIP endpoint with digest authentication
   - Context: `internal`
   - Codecs: ulaw, alaw (conservative, widely supported)
   - Purpose: Test registration and call origination

2. **Endpoint 2000**: AI service placeholder
   - Temporary endpoint for development testing
   - Dialplan routes to echo test with confirmation prompt
   - Purpose: Validate bidirectional audio without Elixir integration
   - Future: Will be replaced by Elixir ARI-controlled endpoint

3. **Transport**: UDP on 0.0.0.0:5060
   - Simple, widely compatible
   - No TLS for development (added in production)
   - Bind to all interfaces for local testing

4. **Dialplan Strategy**:
   - `internal` context: Main development context
   - Extension 2000: Answer → Playback → Echo → Hangup
   - Extension 1002: Simple echo test
   - Invalid extension handler: Prevent misrouting
   - Modular structure for future expansion

5. **RTP Configuration**:
   - Port range: 10000-10100 (101 ports)
   - Sufficient for development testing
   - No ICE/STUN/DTLS in development (simplicity)
   - Production will add encryption and NAT traversal

**Why this approach:**

- **Minimal viable telephony**: Just enough to test registration and audio
- **No Elixir dependency**: Can test with Linphone before ARI integration
- **Reproducible**: Version-controlled configuration
- **Safe**: No anonymous access, authentication required
- **Extensible**: Dialplan structured for future growth

**Consequences:**

- Linphone can register and make test calls
- Bidirectional audio can be verified
- Call flow works without AI integration
- Configuration is isolated from system files
- Easy to reset/reapply during development

**Future evolution:**

- Phase 3: Replace endpoint 2000 with ARI-controlled call flow
- Phase 4: Add AudioSocket media transport
- Phase 11: Add TLS, SRTP, firewall rules

---

## Blockers Update

| # | Blocker | Severity | Resolution path |
|---|---------|----------|------------|
| B1 | Asterisk not installed → media/module facts unverified | High (blocks Phase 2+) | **RESOLVED (Phase 2A):** Asterisk 22.5.2 installed; modules verified via `module show` |
| B2 | `chan_websocket` availability unconfirmed; apt build (22.5.2) predates documented 22.6.0 | Medium | **RESOLVED (Phase 2A):** Confirmed NOT present; AudioSocket selected as primary transport |
| B3 | ~~Elixir/Mix missing + OTP 29 vs Elixir 1.18 mismatch~~ | ~~High~~ | **RESOLVED (Phase 0.5, ADR-0006):** installed Elixir 1.20.2 (OTP-29 precompiled build); compatibility verified |
| B4 | No GPU/CUDA + constrained RAM → local heavy inference infeasible | Medium | Offload inference; dev uses tiny models (Piper/faster-whisper-tiny/small Ollama) |
| B5 | PRoot/Termux: no Docker, systemd not init, UDP/RTP reliability uncertain | Medium | Direct processes in dev (ADR-0007); validate SIP/RTP in Phase 2B; production on VPS |
| B6 | Linphone testing not completed → telephony not validated | Medium | Phase 2B: Complete manual testing with Linphone device |

No irreversible decisions were made. All choices are reversible based on new evidence from later phases.
