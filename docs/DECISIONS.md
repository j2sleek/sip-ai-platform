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

---

## ADR-0010 — OpenCode as the conversational brain, via a telephony MCP server

**Status:** Accepted (Phase 6)

**Context:** The product vision is a live, bidirectional voice meeting where an
AI can plan and discuss features with the user, and can call the user with
updates on dev tasks. Rather than build a bespoke agent loop and a bespoke tool
surface, we can reuse OpenCode (a coding agent) as the **brain** and let it drive
the voice platform through the Model Context Protocol (MCP).

**Decision:** Split the voice agent into two halves with a clean boundary:

- **Brain** — OpenCode, extended with a **telephony MCP server**
  (`apps/telephony_mcp`) that exposes `originate_call`, `speak`,
  `wait_for_input`, `hangup`, `get_transcript`, and a `call://{id}/transcript`
  resource. The brain reasons and decides *what* to say and do.
- **Body** — stays in the platform: Asterisk (SIP/RTP), `voice_core` (per-call
  sessions, media, turn-taking, barge-in), and Python `stt`/`tts`/`vad`/`llm`.
  The body owns real-time audio and endpointing.

Voice therefore becomes **one more I/O modality for the brain**, not a separate
agent implementation. MCP is the integration seam.

**Consequences:**

- The real-time loop (AudioSocket media, endpointing, barge-in) stays in the
  Elixir/Python runtimes where latency and concurrency are managed; the brain is
  not in the audio path.
- `control_api` owns the HTTP call surface the MCP server drives; the MCP server
  is a thin, stateless adapter (owns no call state).
- Requires Asterisk to be present for real calls; a `simulated` backend lets the
  entire brain-side loop run and be tested with no telephony stack.

**Alternatives considered:** a bespoke in-Elixir agent with custom tool calling
(rejected: duplicates a coding agent we already run and couples the brain to the
media runtime); n8n as the orchestrator (rejected for the real-time loop; still
fine for non-real-time business automation).

---

## ADR-0011 — Lightweight, dependency-free providers with external backends

**Status:** Accepted (Phase 6)

**Context:** The platform must run end-to-end on a constrained host (ARM64,
proot, no GPU) while remaining production-ready. Bundling model weights or heavy
Python frameworks would make the foundation slow and fragile.

**Decision:** Every Python service (`stt`, `llm`, `tts`, `vad`) is **standard
library only** and exposes a swappable provider interface:

- **`stt`** — `mock` (default) | `command` (e.g. whisper.cpp on stdin/stdout).
- **`llm`** — `mock` (default, echoes) | `ollama` (`/api/chat`, explicit timeout).
- **`tts`** — `mock` (default, deterministic tone) | `command` (e.g. Piper).
- **`vad`** — `energy` (RMS; default). The Elixir core keeps its own pure energy
  VAD in `VoiceCore.VoiceAgent.Turn`.

Mock providers make the whole platform runnable and testable with zero downloads
and zero secrets. Real backends are opt-in via environment variables, and remain
external processes/services (AGENTS.md rule 15: no heavy inference on the BEAM).

**Audio wire format:** 16-bit signed PCM, **big-endian**, mono — matching the
AudioSocket transport. `tts` returns `audio/pcm`; `stt` accepts raw PCM.

**Consequences:** Fast CI, no model downloads in the foundation, and a trivial
path to swap in real backends. Limitation: mock audio is not real speech; no
sample-rate conversion (documented per service).

---

## ADR-0012 — Outbound call control: control_api surface with simulated/ARI backends

**Status:** Accepted (Phase 6)

**Context:** Outbound calls (the brain calling the user) are a first-class
requirement. SIP signaling must not live in the AI agent (AGENTS.md rule 2), and
the environment used for development has no Asterisk.

**Decision:** `control_api` owns the **outbound-call HTTP API** and a pluggable
`CallBackend`:

- **`simulated`** (default) — a fully in-memory call that emits a realistic event
  sequence and canned caller utterances. Enables demos/tests with no telephony.
- **`ari`** — originates/hangs up channels through **Asterisk ARI**
  (`POST /ari/channels`, `DELETE /ari/channels/{id}`); media/TTS remain owned by
  `voice_core`. `speak` records the agent utterance and delegates playback to the
  media pipeline.

Call *control* state and the per-call event log (long-poll `GET
/api/v1/calls/:id/events`) live in `control_api`; call *media/session* state stays
in `voice_core`, correlated by `call_id`. The telephony MCP server drives this
surface.

**Consequences:** The brain-side loop is demonstrable and tested without
Asterisk; real telephony is a configuration switch. An optional bearer token
(`CONTROL_API_TOKEN`) guards `/api/v1/*`.

---

## ADR-0013 — Node toolchain: TypeScript 7, Fastify 5, MCP SDK 1.x

**Status:** Accepted (Phase 6)

**Context:** "Latest packages as at October 2026" was requested, but toolchain
bleeding edges can break builds.

**Decision:** Adopt the latest stable Oct-2026 versions and verify with a real
build + test:

- `typescript@7.0.2` (native compiler) — **verified** to build `control_api` and
  `telephony_mcp`. Note: TypeScript 7 requires an explicit `"types": ["node"]`
  in `tsconfig` for Node globals (auto-inclusion of `@types/*` was not applied).
- `fastify@5.12.5` (0 audit vulnerabilities after `npm audit fix`).
- `@modelcontextprotocol/sdk@1.32.1` with `zod@4.6.6` (SDK supports zod `^3.25 || ^4`).
- `tsx@4.23.x`, `@types/node@26.6.x`, Node `26.10.0`.

**Consequences:** Modern toolchain, verified by CI (`scripts/test-all.sh`).
Fallback if any version regresses: pin TypeScript `^5.9` (documented in the app
READMEs/troubleshooting).

---

## ADR-0014 — Keep-alive connections for outbound provider calls

**Status:** Accepted (live-call latency follow-up)

**Context:** A voice turn makes an STT, an LLM and a TTS call in quick
succession, each going out to a cloud provider (Groq by default) from the Python
service. `urllib.request.urlopen` opens a fresh TCP (and TLS) connection per
request and drops it immediately, so every turn paid DNS + TCP + TLS setup again
(~0.3–0.4 s per request over the host's mobile uplink) — a large share of the
per-turn latency measured on a real Linphone call.

**Decision:** The STT/LLM/TTS services make their outbound provider calls through
a small, standard-library-only keep-alive helper (`<service>/src/<service>/httpclient.py`):

- it keeps a bounded pool of idle HTTP/1.1 connections per origin
  (`scheme://host:port`, default `HTTP_MAX_IDLE=8`) and reuses them, so the
  handshake is paid once per burst rather than once per request;
- it presents the same call shape (`urlopen(request, timeout)` returning a
  context-manager response) and raises the same exceptions
  (`urllib.error.HTTPError` for non-2xx, `urllib.error.URLError` for connection
  failures) as `urllib`, so providers are unchanged and failures stay classified;
- a stale pooled connection (server-side keep-alive timeout) is retried once on
  a fresh connection; a request timeout is never retried (it may be mid-flight);
- it follows redirects like `urllib` (301/302/303 → GET; 307/308 keep method);
- it disables itself (`HTTP_KEEPALIVE=0`) or falls back to plain `urllib` when an
  HTTP proxy is configured, since proxies are not pooled here.

The helper is duplicated per service because the Python runtimes are
independently buildable (AGENTS.md) — there is no shared Python package.

**Consequences:** Measurably lower per-turn latency and fewer sockets to the
provider. The localhost Elixir→Python hop already used `:httpc` connection
pooling, so only the cloud hop changed. Limitation: one extra retry is possible
on a connection error (never on a timeout); proxied deployments do not benefit.

---

## ADR-0015 — Robust turn-taking: safe timers, per-turn sequencing, bounded replies

**Status:** Accepted (live-call reliability follow-up)

**Context:** A live Linphone call exposed three compounding problems in
`VoiceCore.VoiceAgent`:

1. **State corruption → dropped call.** `start_speaking/2` stored the *return
   value* of `cancel_timer/1` in `playback_timer`. `Process.cancel_timer/1`
   returns a boolean or a remaining-ms integer (or the field was already the
   atom `:ok`), so a later `cancel_timer/1` on that non-reference value raised
   `ArgumentError: not a reference`. It crashed the agent on the next
   barge-in/terminate; `CallSession` treats an abnormal child exit as fatal, so
   the **whole call ended** ("I didn't get any response again").
2. **Overlapping turns / out-of-order speech.** Barge-in during `:processing`
   moved the agent to `:listening` but did not cancel the in-flight STT/LLM
   turn, so a late reply from the superseded turn could be spoken *after* the
   caller had moved on. Endpointing while `:processing` silently dropped the
   caller's new utterance instead of answering it.
3. **Growing per-turn latency.** The model's replies grew each turn (31 → 310
   chars); cloud TTS latency and playback time both scale with length (a 310-char
   reply took ~5 s to synthesize *and* ~22 s to play), so turns felt slower and
   slower.

**Decision:**

- `cancel_timer/1` accepts only `nil`/a timer reference, never raises, and always
  returns `:ok`; callers never store its result. `playback_timer` is reset to
  `nil` explicitly.
- Every caller utterance gets a monotonic `turn_seq`; STT and brain results carry
  it and are dropped when stale. A new endpoint supersedes any in-flight turn
  (no silent drops); a barge-in invalidates the pending turn so its reply can
  never speak over the caller. A `{:speak, ...}` from the bridge also invalidates
  the in-flight local turn.
- Spoken replies are clamped to `AGENT_MAX_REPLY_CHARS` (default 320) on a
  sentence/word boundary, the HTTPLLM system prompt asks for ~30-word replies,
  and `start_production.sh` lowers the Groq `LLM_MAX_TOKENS` default (320) with
  `LLM_REASONING_EFFORT=low`.

**Consequences:** Calls survive barge-in and barge-in-during-thinking; utterance
answers stay in order; per-turn latency is bounded by a constant instead of
growing with conversation length. Trade-off: very long answers are truncated
(raise `AGENT_MAX_REPLY_CHARS` / `LLM_MAX_TOKENS` to trade latency for length).

---

## ADR-0016 — `VOICE_BRAIN=external`: letting OpenCode answer the call

**Status:** Accepted (OpenCode-integration follow-up)

**Context:** ADR-0010 defines OpenCode as the brain, and the plumbing exists —
`control_api` exposes `originate_call`/`speak`/`events`, `telephony_mcp` wraps it
for OpenCode, and `voice_core.ControlBus` polls `agent.speak` and forwards it to
the agent. But the body *always* answered with its own `VoiceCore.Brain`
(`llm`/`static`), so an OpenCode `speak` would collide with the local reply: there
was no way to make OpenCode the sole brain.

**Decision:** Add `VoiceCore.Brain.External`, selected with
`VOICE_BRAIN=external` (with `CONTROL_API_ENABLED=true`). In this mode
`respond/3` returns `{:ok, ""}`: the body transcribes the caller, reports
`utterance.user` to `control_api`, stands down to `:idle`, and says nothing
locally. The reply arrives asynchronously as an `agent.speak` instruction from
OpenCode, which `ControlBus` forwards and the agent speaks. An empty brain reply
therefore means "defer to the bridge".

**Consequences:** OpenCode can now drive a call end-to-end
(`originate_call` → loop of `wait_for_input` → `speak` → `hangup`). `VOICE_BRAIN=llm`
remains the default low-latency body-side brain; `external` trades the local
model for full OpenCode reasoning (higher turn latency, no local fallback). If
`control_api` is disabled or does not know the call, `external` mode never
answers — use `llm` for unattended calls. No SIP/Asterisk logic moves into the
brain (AGENTS.md rules 1–3 stay intact).

## ADR-0017 — Direction decides the brain, plus a latency filler

**Status:** Accepted (OpenCode-integration follow-up)

**Context:** After ADR-0015/0016 we had two working extremes, verified live:
`VOICE_BRAIN=llm` is fast (~1 s) but stateless — it knows nothing about the
project; `VOICE_BRAIN=external` gives OpenCode's full context and tools but costs
seconds per turn (an agent loop, not one model call). The two are good at
opposite jobs, and the job is decided by *who owns the call*:

* a call the user **dials in** wants a fast, always-available answer;
* a call **OpenCode originates** wants OpenCode's reasoning, and a few seconds of
  latency is acceptable — but silence is not.

Feeding project context into the local LLM was considered and rejected for now:
it inflates the prompt on every turn (token budget on the free tier).

**Decision:**

1. **Direction decides the brain (`VOICE_BRAIN=auto`).** Add
   `VoiceCore.Brain.Auto`, which routes per call on a bridge hint:
   * `:attached` — `control_api` knows the call (OpenCode-originated) → defer to
     `VoiceCore.Brain.External` (the body transcribes + reports; OpenCode owns
     *what to say* via the MCP `speak` path).
   * `:absent` / `:unknown` — inbound, or not yet resolved → answer with
     `:brain_local` (`VoiceCore.Brain.HTTPLLM`), so a dial-in call is never
     silent.

   `VoiceCore.ControlBus` — which already discovers whether `control_api` knows
   the call (`:not_found` for inbound) — is the oracle: it sends the agent
   `{:bridge, :attached | :absent}` once, and the agent passes `bridge` in the
   brain context. `auto` becomes the `start_production.sh` default; `llm`,
   `external`, `static` stay available.

2. **Latency filler (Layer 2).** When the brain defers (an empty reply — i.e. a
   bridged call), the agent starts a filler timer. If nothing is spoken within
   `AGENT_FILLER_DELAY_MS` (default 900 ms), it speaks a short rotating phrase
   (`AGENT_FILLER_TEXTS`) — "Let me check on that." — so the caller hears
   acknowledgment at ~1 s while OpenCode composes the real answer, which then
   supersedes it through the normal `speak`/barge-in path. The filler is
   cancelled the moment real speech arrives, on a newer turn, or on hangup, and
   is skipped for `:absent` calls (where it would only precede silence). It costs
   no model tokens.

**Consequences:** An OpenCode-originated call now feels responsive (instant local
acknowledgment) while still getting OpenCode's full, tool-using answer; an
inbound call is answered fast by the local model. No SIP/Asterisk logic moves
into the brain, media stays behind `MediaTransport`, and the brain/body split is
intact (AGENTS.md rules 1–5). Known limits: inbound calls have no OpenCode hook,
so they cannot delegate to OpenCode (an agent would have to discover the call via
`list_calls`) — **superseded by ADR-0018**, which registers inbound calls with
`control_api` so they get a bridge too; the filler is a single masked gap, not a
queue — a very long OpenCode turn may still leave silence after it; and
`:unknown`-bridge turns fall back to the local brain, so a rare first-turn race
can produce a local answer on an OpenCode call.

## ADR-0018 — Inbound calls register with control_api and delegate to OpenCode

**Status:** Accepted (OpenCode-integration follow-up)

**Context:** ADR-0017 made direction decide the brain, but only calls
`control_api` *originated* had a bridge: an inbound call (dialled into the `[ai]`
Stasis app) was reported to `control_api` as an unknown id, so the bridge stood
down (`:bridge absent`) and the local, stateless LLM answered. A live inbound
call asking for a project status report produced a confident, entirely
hallucinated answer — the local model has no project context (Layer 1 was
deliberately left out to protect the free-tier token budget). The fix the user
asked for is not "give the local model context" but "let inbound calls delegate
to OpenCode", i.e. give them a bridge.

**Decision:**

1. **`control_api` registers inbound calls on first ingest.**
   `POST /api/v1/calls/:id/events` no longer 404s for an unknown id: a call
   `control_api` did not originate is, by definition, an inbound call (it entered
   Stasis from the dialplan), so the registry creates it with
   `direction: "inbound"` and the reporting body's `channel_id` in `meta` (used by
   the ARI backend to hang the right channel up). `CallRecord` gains a
   `direction: "inbound" | "outbound"` field, surfaced by `GET /calls` so an MCP
   client can tell them apart. Unsupported event *types* are still rejected with
   `400` **before** any registration, so bad input cannot create a call.

2. **`voice_core` reports direction and channel at call start.** The ARI
   dispatcher classifies a channel as `:outbound` when its id is the call id
   (a UUID — control_api set `channelId = call_id`) and `:inbound` otherwise.
   `CallSession` carries `direction`, includes `channel_id`/`from`/`to`/
   `direction` in its `call.answered` report (sent on media-ready, before the
   `ControlBus` starts, so registration always wins the race), and passes
   `direction` to `ControlBus`.

3. **Inbound calls get a bridge and delegate.** Because registration happens
   before the bus's first poll, the bus now gets `:attached` for inbound calls
   too, so `Brain.Auto` defers to `Brain.External` — the hallucinating local model
   is out of the inbound path. Since no backend queues a greeting for an inbound
   call, `ControlBus` speaks the configured local greeting **once** for
   `:inbound` calls (a greeting is not an answer, and it avoids dead air while
   OpenCode notices the call). The `:not_found` → `{:bridge, :absent}` path is
   kept as a fallback (registration failed, or the bridge was disabled mid-call).

**Consequences:** An inbound call is now a first-class `control_api` call: an
OpenCode session discovers it with `list_calls` and drives it with
`wait_for_input` → `speak` → `hangup`, exactly like an originated call. The
local hallucination is gone from the inbound path. Trade-off: because inbound
calls now *defer*, an inbound call with **no OpenCode session watching** gets the
local greeting and then silence — the same contract as `VOICE_BRAIN=external`
(ADR-0016). Run an OpenCode poll loop when you want dial-ins answered fully; use
`VOICE_BRAIN=llm` if unattended dial-ins must always be answered locally. No
SIP/Asterisk control logic moves into the brain; media stays behind
`MediaTransport`; the brain/body split is intact (AGENTS.md rules 1–5).
