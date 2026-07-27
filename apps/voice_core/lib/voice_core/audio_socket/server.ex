defmodule VoiceCore.AudioSocket.Server do
  @moduledoc """
  TCP server for AudioSocket connections.

  Listens on 127.0.0.1:9019 and handles AudioSocket protocol connections
  from Asterisk. Manages connection lifecycle, frame parsing, and audio
  distribution to call sessions.
  """

  use GenServer

  require Logger

  @doc """
  Configuration structure for the AudioSocket server.
  """
  defmodule Config do
    defstruct host: "127.0.0.1", port: 9019
  end

  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    Logger.info("AudioSocket server starting with config: #{inspect(config)}")

    # Minimal working init - just return ok state
    # TODO: Add actual TCP listener in next iteration

    state = %{
      config: config,
      status: :initialized
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      status: state.status,
      config: state.config
    }
    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("AudioSocket server shutting down")
    :ok
  end

  @doc """
  Get server statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Get the server configuration.
  """
  def config do
    Application.get_env(:voice_core, :audiosocket, Config.__struct__())
  end
end
