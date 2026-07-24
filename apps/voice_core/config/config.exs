import Config

# Compile-time configuration. Environment-driven values are resolved at runtime
# in runtime.exs; this file only sets safe, static defaults.

config :voice_core,
  # Overridden at runtime from APP_ENV. Kept here so the key always exists.
  app_env: "development"

# Logger default; the level is overridden at runtime from LOG_LEVEL.
config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:call_id, :session_id]

import_config "#{config_env()}.exs"
