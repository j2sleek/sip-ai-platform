defmodule VoiceCore.Application do
  @moduledoc """
  OTP application entry point for `voice_core`.

  Starts a minimal, intentionally empty supervision tree. Future phases attach
  supervised children here (ARI connection, call registry, call supervisor,
  provider supervisor, tool supervisor) as described in
  `MEDIA-STREAMING-DECISION.md`. In Phase 0.5 the tree has no children — its only
  job is to prove the OTP foundation starts and stops cleanly.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # AudioSocket server configuration
    audiosocket_config = %{
      host: "127.0.0.1",
      port: 9019
    }

    children = [
      # Registry for tracking active calls
      {Registry, keys: :unique, name: VoiceCore.CallRegistry},
      # Supervisor for individual call sessions
      {VoiceCore.CallSupervisor, []},
      # AudioSocket server for bidirectional PCM audio transport
      {VoiceCore.AudioSocket.Server, audiosocket_config}
    ]

    # `:one_for_one` — when a child crashes only that child is restarted. This
    # is the correct default for the independent, isolated subsystems this tree
    # will later supervise.
    opts = [strategy: :one_for_one, name: VoiceCore.Supervisor]

    Logger.info("VoiceCore starting supervision tree")
    Supervisor.start_link(children, opts)
  end
end
