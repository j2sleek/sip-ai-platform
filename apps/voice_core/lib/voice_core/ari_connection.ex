defmodule VoiceCore.ARIConnection do
  @moduledoc """
  Supervised connection to Asterisk ARI WebSocket.
  """

  use WebSockex
  require Logger

  # --- API ---

  def start_link(config) do
    # Initiate connection
    case do_connect(config) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error("ARI connection failed: #{inspect(reason)}")
        # Start a dummy process or handle failure more robustly to keep supervisor alive
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end
  end

  defp do_connect(config) do
    url = "#{config.url}/ari/events?app=#{config.app}"
    headers = [{"Authorization", "Basic #{Base.encode64("#{config.user}:#{config.pass}")}"}]
    WebSockex.start_link(url, __MODULE__, config, extra_headers: headers, name: __MODULE__)
  end

  # --- WebSockex Callbacks ---

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("ARI WebSocket connected")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    Logger.debug("ARI event received: #{msg}")

    case VoiceCore.ARI.Decoder.decode(msg) do
      {:ok, event} ->
        VoiceCore.ARI.Dispatcher.dispatch(event)

      {:error, reason} ->
        Logger.error("ARI event decoding failed: #{inspect(reason)}")
    end

    {:ok, state}
  end

  @impl true
  def handle_disconnect(disconnect_info, state) do
    Logger.warning("ARI WebSocket disconnected: #{inspect(disconnect_info)}")
    {:ok, state}
  end
end
