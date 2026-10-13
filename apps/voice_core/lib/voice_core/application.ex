defmodule VoiceCore.Application do
  @moduledoc """
  OTP application entry point for `voice_core`.

  Supervision tree (all `:one_for_one` — a child crash restarts only that child):

    * `VoiceCore.CallRegistry`     — OTP Registry keyed by call_id / channel /
                                     media ids
    * `VoiceCore.CallSupervisor`   — DynamicSupervisor for per-call processes
    * `VoiceCore.AudioSocket.Server` — TCP AudioSocket media server
    * `VoiceCore.ARIConnection`    — optional ARI WebSocket client, started
                                     only when `ARI_ENABLED=true`

  The tree is deliberately Asterisk-agnostic: it boots cleanly with no
  telephony present (dev, CI, tests) and attaches ARI when configured.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    audiosocket_config =
      Application.get_env(:voice_core, :audiosocket, host: "127.0.0.1", port: 9019)
      |> Map.new()

    children = [
      {Registry, keys: :unique, name: VoiceCore.CallRegistry},
      VoiceCore.CallSupervisor,
      {VoiceCore.AudioSocket.Server, audiosocket_config}
    ]

    children =
      if Application.get_env(:voice_core, :ari, [])[:enabled] do
        ari_config = Application.get_env(:voice_core, :ari) |> Map.new()
        children ++ [{VoiceCore.ARIConnection, ari_config}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: VoiceCore.Supervisor]
    Logger.info("VoiceCore starting supervision tree (ari_enabled=#{ari_enabled?()})")
    Supervisor.start_link(children, opts)
  end

  defp ari_enabled? do
    Application.get_env(:voice_core, :ari, [])[:enabled] == true
  end
end
