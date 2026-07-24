import Config

# Runtime configuration — read from environment variables on every boot.
# This is where all environment-driven config lives. No secrets are defined
# here in Phase 1 (telephony/AI config arrives in later phases).

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
