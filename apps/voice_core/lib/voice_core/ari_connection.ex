defmodule VoiceCore.ARIConnection do
  @moduledoc """
  Supervised WebSocket client to the Asterisk ARI `/ari/events` stream.

  Started only when `ARI_ENABLED=true` (see `config/runtime.exs`), so the app
  boots cleanly without telephony. Uses `WebSockex` with automatic reconnection:
  a failed connect surfaces as `{:error, reason}` (supervisor restarts it) and a
  dropped connection reconnects with bounded backoff — never a silent dummy
  process (see ADR-0010 / AGENTS.md rule 13).
  """

  use WebSockex
  require Logger

  # ─── API ────────────────────────────────────────────────────────────────────

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    url = "#{config[:url]}/ari/events?app=#{config[:app]}"
    headers = [{"Authorization", "Basic " <> Base.encode64("#{config[:user]}:#{config[:pass]}")}]

    WebSockex.start_link(url, __MODULE__, %{config: config, reconnect_attempts: 0},
      extra_headers: headers,
      name: __MODULE__
    )
  catch
    :exit, reason -> {:error, {:websockex_start_failed, reason}}
  end

  # ─── WebSockex callbacks ─────────────────────────────────────────────────────

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("ARI WebSocket connected")
    :telemetry.execute([:voice_core, :ari, :connected], %{})
    {:ok, Map.put(state, :reconnect_attempts, 0)}
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

    case state.reconnect_attempts do
      attempts when attempts < 5 ->
        backoff = (500 * :math.pow(2, attempts)) |> round()
        Process.send_after(self(), :reconnect_now, backoff)
        {:ok, Map.put(state, :reconnect_attempts, attempts + 1)}

      _ ->
        # Permanent failure after bounded retries — let the supervisor restart.
        {:stop, :permanent_disconnect}
    end
  end

  @impl true
  def handle_info(:reconnect_now, state) do
    {:reconnect, state}
  end

  def handle_info(_msg, state), do: {:ok, state}
end
