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
  user: System.get_env("ARI_USERNAME", "sip_ai_platform"),
  pass: System.get_env("ARI_PASSWORD", ""),
  app: System.get_env("ARI_APP_NAME", "sip_ai_platform")

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
  silence_frames_to_endpoint: 6
