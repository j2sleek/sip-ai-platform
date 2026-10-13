import Config

# Keep tests quiet unless explicitly overridden.
config :logger, level: :warning

# Bind an ephemeral AudioSocket port so test runs never collide with a real
# Asterisk (or a parallel test run).
config :voice_core, :audiosocket, host: "127.0.0.1", port: 0

# ARI stays disabled in tests (no Asterisk available); the app must still boot.
config :voice_core, :ari, enabled: false
