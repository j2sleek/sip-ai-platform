defmodule VoiceCore.MediaSession do
  @moduledoc """
  `VoiceCore.MediaSession` owns one call's media stream behind a
  `VoiceCore.MediaTransport` adapter.

  Responsibilities:

    * register as the call's media process (`{:media, call_id}`, plus a
      transport-level `{:media, conn_id}` alias once attached) so the transport
      can route inbound audio/DTMF here — isolated per call (AGENTS.md rule 6);
    * count/observe inbound audio and DTMF;
    * push inbound PCM to the call's `VoiceCore.VoiceAgent` for endpointing;
    * send outbound PCM (TTS output) back over the transport.

  Counters are exposed via `stats/1` (frames rx/tx, DTMF) and telemetry.
  """

  use GenServer
  require Logger

  # ─── API ────────────────────────────────────────────────────────────────────

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) do
    call_id = Map.fetch!(args, :call_id)
    GenServer.start_link(__MODULE__, args, name: via_tuple(call_id))
  end

  @doc "Binds this session to a live transport connection (AudioSocket conn id)."
  @spec attach_transport(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def attach_transport(pid_or_name, conn_id) do
    GenServer.call(pid_or_name, {:attach_transport, conn_id}, 10_000)
  end

  @doc "Sends one outbound PCM chunk to the far end on the attached connection."
  @spec send_audio(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_audio(pid_or_name, pcm) when is_binary(pcm) do
    GenServer.call(pid_or_name, {:send_audio, pcm}, 10_000)
  end

  @doc "Session media statistics."
  @spec stats(GenServer.server()) :: map()
  def stats(pid_or_name) do
    GenServer.call(pid_or_name, :stats, 5_000)
  end

  defp via_tuple(call_id) do
    {:via, Registry, {VoiceCore.CallRegistry, {:media, call_id}}}
  end

  # ─── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    call_id = Map.fetch!(args, :call_id)
    Logger.info("MediaSession starting for call #{call_id}")

    state = %{
      call_id: call_id,
      transport: Map.get(args, :transport, VoiceCore.MediaTransport.AudioSocket),
      conn_id: nil,
      listener: Map.get(args, :listener),
      connected_at: NaiveDateTime.utc_now(),
      audio_frames_rx: 0,
      audio_frames_tx: 0,
      dtmf_events: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:attach_transport, conn_id}, _from, state) do
    case state.transport.attach(conn_id, self()) do
      :ok ->
        # Alias registration: transport routes for this conn to *this* process.
        Registry.register(VoiceCore.CallRegistry, {:media, conn_id}, self())
        Logger.info("MediaSession #{state.call_id}: attached transport conn #{conn_id}")

        {:reply, :ok, %{state | conn_id: conn_id}}

      {:error, reason} ->
        Logger.warning("MediaSession #{state.call_id}: attach failed (#{inspect(reason)})")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_audio, _pcm}, _from, %{conn_id: nil} = state) do
    {:reply, {:error, :not_attached}, %{state | audio_frames_tx: state.audio_frames_tx + 1}}
  end

  def handle_call({:send_audio, pcm}, _from, state) do
    case state.transport.send_audio(state.conn_id, pcm) do
      :ok ->
        :telemetry.execute([:voice_core, :media, :tx], %{bytes: byte_size(pcm)}, %{
          call_id: state.call_id
        })

        {:reply, :ok, %{state | audio_frames_tx: state.audio_frames_tx + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, session_stats(state), state}
  end

  @impl true
  def handle_info({:audio_frame_rx, pcm}, state) do
    :telemetry.execute([:voice_core, :media, :rx], %{bytes: byte_size(pcm)}, %{
      call_id: state.call_id
    })

    if is_pid(state.listener) do
      send(state.listener, {:audio, pcm})
    end

    {:noreply, %{state | audio_frames_rx: state.audio_frames_rx + 1}}
  end

  def handle_info({:dtmf_frame, digit}, state) do
    Logger.debug("MediaSession #{state.call_id}: DTMF digit #{inspect(digit)}")
    if is_pid(state.listener), do: send(state.listener, {:dtmf, digit})
    {:noreply, %{state | dtmf_events: [digit | state.dtmf_events]}}
  end

  def handle_info({:audio_connected, transport_ref}, state) do
    Logger.info("MediaSession #{state.call_id}: media connected")

    cond do
      is_binary(transport_ref) -> {:noreply, %{state | conn_id: transport_ref}}
      true -> {:noreply, state}
    end
  end

  def handle_info(:media_disconnected, state) do
    Logger.info("MediaSession #{state.call_id}: media disconnected")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn_id do
      state.transport.detach(state.conn_id)
    end

    Logger.info("MediaSession #{state.call_id}: terminating")
    :ok
  end

  defp session_stats(state) do
    %{
      call_id: state.call_id,
      conn_id: state.conn_id,
      audio_frames_rx: state.audio_frames_rx,
      audio_frames_tx: state.audio_frames_tx,
      dtmf_count: length(state.dtmf_events),
      connected_at: state.connected_at
    }
  end
end
