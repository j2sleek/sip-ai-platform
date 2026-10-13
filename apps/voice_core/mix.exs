defmodule VoiceCore.MixProject do
  use Mix.Project

  @moduledoc false

  def project do
    [
      app: :voice_core,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :telemetry],
      mod: {VoiceCore.Application, []}
    ]
  end

  # Deliberately minimal. Jason parses ARI events; WebSockex powers the ARI
  # WebSocket client (and reconnection). Everything else (HTTP, TCP, JSON
  # encoding, VAD math) uses OTP + BEAM built-ins so the core stays light.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:websockex, "~> 0.5"},
      {:telemetry, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      # `mix test` keeps the doc/format gates used by scripts/test-all.sh
      test: ["format --check-formatted", "compile --warnings-as-errors", "test"]
    ]
  end
end
