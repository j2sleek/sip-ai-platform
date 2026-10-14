import Config

# Runtime configuration — read from environment variables on every boot.
# All values here have safe development defaults; secrets are never defined
# here (see AGENTS.md → Security). Copy `.env.example` to `.env` to override.

app_env = System.get_env("APP_ENV", "development")

log_level =
  case System.get_env("LOG_LEVEL", "info") do
    "debug" -> :debug
    "info" -> :info
    "warning" -> :warning
    "warn" -> :warning
    "error" -> :error
    other -> raise "invalid LOG_LEVEL: #{inspect(other)} (use debug|info|warning|error)"
  end

config :voice_core, app_env: app_env
config :logger, level: log_level

# ─── AudioSocket media server (self-hosted, localhost-only by default) ──────
# In the test env, `config/test.exs` binds an ephemeral port; don't clobber it.
if config_env() != :test do
  config :voice_core, :audiosocket,
    host: System.get_env("AUDIOSOCKET_BIND_HOST", "127.0.0.1"),
    # 0 = ephemeral; default 9019 for Asterisk chan_audiosocket.
    port: System.get_env("AUDIOSOCKET_BIND_PORT", "9019") |> String.to_integer()
end

# ─── Asterisk ARI connection (started only when ARI_ENABLED=true) ───────────
config :voice_core, :ari,
  enabled: System.get_env("ARI_ENABLED", "false") == "true",
  url: System.get_env("ARI_BASE_URL", "http://127.0.0.1:8088"),
  user: System.get_env("ARI_USERNAME", "voice_core"),
  pass: System.get_env("ARI_PASSWORD", ""),
  app: System.get_env("ARI_APP_NAME", "voice_core")

# ─── AI provider endpoints (utterance-granularity HTTP calls) ───────────────
int_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> value |> String.to_integer()
  end
end

float_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Float.parse(value) do
        {parsed, _rest} -> parsed
        :error -> default
      end
  end
end

config :voice_core, :ai,
  stt_url: System.get_env("STT_URL", "http://127.0.0.1:5001"),
  llm_url: System.get_env("LLM_URL", "http://127.0.0.1:5002"),
  tts_url: System.get_env("TTS_URL", "http://127.0.0.1:5003"),
  vad_url: System.get_env("VAD_URL", "http://127.0.0.1:5004"),
  stt_timeout_ms: int_env.("STT_TIMEOUT_MS", 15_000),
  llm_timeout_ms: int_env.("LLM_TIMEOUT_MS", 30_000),
  tts_timeout_ms: int_env.("TTS_TIMEOUT_MS", 15_000),
  vad_timeout_ms: int_env.("VAD_TIMEOUT_MS", 5_000)

# Filler phrases spoken while the external brain (OpenCode) composes its reply
# (Layer 2, see ADR-0017). Comma-separated; empty falls back to the default.
filler_texts =
  System.get_env(
    "AGENT_FILLER_TEXTS",
    "Let me check on that.,One moment.,Let me take a look."
  )
  |> String.split(",")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> case do
    [] -> ["Let me check on that.", "One moment.", "Let me take a look."]
    texts -> texts
  end

# ─── Turn/endpoint heuristics for the in-core voice agent body ──────────────
# All time-based so the endpoint window does not depend on the media backend's
# frame size (Asterisk AudioSocket delivers ~20 ms frames).
config :voice_core, :agent,
  sample_rate: 8000,
  # RMS above this → speech; below → silence (energy VAD on 16-bit PCM)
  vad_threshold: float_env.("VAD_THRESHOLD", 300.0),
  # Trailing silence before an utterance is endpointed (tune for "eager" ↔ "patient")
  silence_ms_to_endpoint: int_env.("VAD_SILENCE_MS", 700),
  # Ignore blips shorter than this (clicks, keypad thumps, single coughs)
  min_speech_ms: int_env.("VAD_MIN_SPEECH_MS", 200),
  # Hard cap on spoken reply length. Bounds TTS synthesis + playback time, which
  # is the dominant per-turn latency for cloud TTS (a 310-char reply took ~5 s
  # to synthesize). Replies are clamped on a sentence/word boundary.
  max_reply_chars: int_env.("AGENT_MAX_REPLY_CHARS", 320),
  # Spoken when a call attaches without a brain-supplied greeting (inbound calls).
  greeting:
    System.get_env("AGENT_GREETING", "Hello, this is the AI assistant. How can I help you?"),
  # Latency filler (Layer 2, ADR-0017): when the brain defers (an empty reply —
  # a bridged/OpenCode call) speak a short local phrase after `filler_delay_ms`
  # unless real speech arrives first, so the caller never sits in silence while
  # OpenCode composes its answer.
  filler_enabled: System.get_env("AGENT_FILLER_ENABLED", "true") == "true",
  filler_delay_ms: int_env.("AGENT_FILLER_DELAY_MS", 900),
  filler_texts: filler_texts,
  # Safety net (ADR-0019): if a deferred (bridged/OpenCode) turn still has no
  # answer after `reply_timeout_ms`, speak `reply_timeout_text` so the caller is
  # never left in silence — e.g. OpenCode is rate-limited or down.
  reply_timeout_ms: int_env.("AGENT_REPLY_TIMEOUT_MS", 8_000),
  reply_timeout_text:
    System.get_env(
      "AGENT_REPLY_TIMEOUT_TEXT",
      "The project agent is unavailable until tomorrow."
    )

# ─── Brain selection ────────────────────────────────────────────────────────
# "llm"      → VoiceCore.Brain.HTTPLLM (calls the platform `llm` service; drives
#              fast turn-taking on its own)
# "external" → VoiceCore.Brain.External (no local reply; the brain is OpenCode
#              over the telephony MCP server, replying via control_api
#              `agent.speak` — requires CONTROL_API_ENABLED=true)
# "auto"     → VoiceCore.Brain.Auto (direction decides: OpenCode-originated
#              calls defer to the external brain; inbound calls answer with the
#              local brain — see ADR-0017)
# "static"   → VoiceCore.Brain.Static  (canned replies; tests/offline default)
brain =
  case System.get_env("VOICE_BRAIN", "static") do
    "llm" -> VoiceCore.Brain.HTTPLLM
    "http_llm" -> VoiceCore.Brain.HTTPLLM
    "external" -> VoiceCore.Brain.External
    "mcp" -> VoiceCore.Brain.External
    "auto" -> VoiceCore.Brain.Auto
    _ -> VoiceCore.Brain.Static
  end

config :voice_core, :brain, brain
# Local brain used by `VOICE_BRAIN=auto` for inbound (unbridged) calls.
config :voice_core, :brain_local, VoiceCore.Brain.HTTPLLM

# ─── control_api bridge (brain ↔ body message bus) ──────────────────────────
# When enabled, the body reports caller/agent turns to control_api and reads
# `agent.speak` instructions from it (how OpenCode/MCP drives a live call).
config :voice_core, :control_api,
  enabled: System.get_env("CONTROL_API_ENABLED", "false") == "true",
  base_url: System.get_env("CONTROL_API_URL", "http://127.0.0.1:4001"),
  token: System.get_env("CONTROL_API_TOKEN", ""),
  request_timeout_ms: int_env.("CONTROL_API_TIMEOUT_MS", 5_000),
  poll_wait_ms: int_env.("CONTROL_API_POLL_WAIT_MS", 1_000)
