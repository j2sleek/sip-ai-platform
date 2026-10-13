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

config :voice_core, :ai,
  stt_url: System.get_env("STT_URL", "http://127.0.0.1:5001"),
  llm_url: System.get_env("LLM_URL", "http://127.0.0.1:5002"),
  tts_url: System.get_env("TTS_URL", "http://127.0.0.1:5003"),
  vad_url: System.get_env("VAD_URL", "http://127.0.0.1:5004"),
  stt_timeout_ms: int_env.("STT_TIMEOUT_MS", 15_000),
  llm_timeout_ms: int_env.("LLM_TIMEOUT_MS", 30_000),
  tts_timeout_ms: int_env.("TTS_TIMEOUT_MS", 15_000),
  vad_timeout_ms: int_env.("VAD_TIMEOUT_MS", 5_000)

# ─── Turn/endpoint heuristics for the in-core voice agent body ──────────────
config :voice_core, :agent,
  sample_rate: 8000,
  # RMS above this → speech; below → silence (energy VAD on 16-bit PCM)
  vad_threshold: 300.0,
  # Consecutive silence frames (100ms each) before an utterance is endpointed
  silence_frames_to_endpoint: 6,
  # Spoken when a call attaches without a brain-supplied greeting (inbound calls).
  greeting:
    System.get_env("AGENT_GREETING", "Hello, this is the AI assistant. How can I help you?")

# ─── Brain selection ────────────────────────────────────────────────────────
# "llm"      → VoiceCore.Brain.HTTPLLM (calls the platform `llm` service; default
#              for production, drives fast turn-taking on its own)
# "static"   → VoiceCore.Brain.Static  (canned replies; tests/offline default)
brain =
  case System.get_env("VOICE_BRAIN", "static") do
    "llm" -> VoiceCore.Brain.HTTPLLM
    "http_llm" -> VoiceCore.Brain.HTTPLLM
    _ -> VoiceCore.Brain.Static
  end

config :voice_core, :brain, brain

# ─── control_api bridge (brain ↔ body message bus) ──────────────────────────
# When enabled, the body reports caller/agent turns to control_api and reads
# `agent.speak` instructions from it (how OpenCode/MCP drives a live call).
config :voice_core, :control_api,
  enabled: System.get_env("CONTROL_API_ENABLED", "false") == "true",
  base_url: System.get_env("CONTROL_API_URL", "http://127.0.0.1:4001"),
  token: System.get_env("CONTROL_API_TOKEN", ""),
  request_timeout_ms: int_env.("CONTROL_API_TIMEOUT_MS", 5_000),
  poll_wait_ms: int_env.("CONTROL_API_POLL_WAIT_MS", 1_000)
