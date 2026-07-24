defmodule VoiceCore.MixProject do
  use Mix.Project

  @moduledoc false

  def project do
    [
      app: :voice_core,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # OTP application. `mod:` starts the supervision tree via VoiceCore.Application.
  def application do
    [
      extra_applications: [:logger],
      mod: {VoiceCore.Application, []}
    ]
  end

  # Intentionally empty in Phase 0.5 — no telephony/AI/media dependencies yet.
  defp deps do
    []
  end
end
