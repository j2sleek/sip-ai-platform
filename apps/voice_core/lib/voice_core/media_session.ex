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

  # Outbound streaming pace. Asterisk's `app_audiosocket` aborts the link after
  # 2 s of no activity *in either direction*, so the server must keep feeding the
  # channel: outbound PCM is drained at real time and digital silence is sent
  # whenever the agent has nothing queued (e.g. while TTS is still synthesizing).
  @tx_tick_ms 20
  @frame_bytes 320

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

    transport = Map.get(args, :transport, VoiceCore.MediaTransport.AudioSocket)

    state = %{
      call_id: call_id,
      transport: transport,
      # Transport-level byte order. Internally PCM is big-endian (matches the
      # TTS contract and the turn detector); the AC-PCM (AudioSocket) wire format
      # is little-endian, so it is converted here — the one place that touches
      # the transport edge.
      byte_order: transport_byte_order(transport),
      conn_id: nil,
      listener: Map.get(args, :listener),
      connected_at: NaiveDateTime.utc_now(),
      audio_frames_rx: 0,
      audio_frames_tx: 0,
      dtmf_events: [],
      # Pending outbound PCM (internal big-endian). Drained at real time by the
      # 20 ms `:tx_tick`; silence is emitted whenever it runs dry.
      tx_queue: <<>>,
      tx_timer: nil
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

        {:reply, :ok, start_tx(%{state | conn_id: conn_id})}

      {:error, reason} ->
        Logger.warning("MediaSession #{state.call_id}: attach failed (#{inspect(reason)})")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_audio, _pcm}, _from, %{conn_id: nil} = state) do
    {:reply, {:error, :not_attached}, %{state | audio_frames_tx: state.audio_frames_tx + 1}}
  end

  # Outbound TTS is *queued*, not written synchronously: the 20 ms `:tx_tick`
  # paces it in real time and fills gaps with silence (keepalive + smooth audio).
  def handle_call({:send_audio, pcm}, _from, state) when is_binary(pcm) do
    {:reply, :ok, start_tx(%{state | tx_queue: state.tx_queue <> pcm})}
  end

  def handle_call(:stats, _from, state) do
    {:reply, session_stats(state), state}
  end

  @impl true
  def handle_info({:audio_frame_rx, pcm}, state) do
    pcm = decode_inbound(pcm, state.byte_order)

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

  # The transport discovered the AudioSocket UUID for this call and handed us the
  # connection id. Bind it (so outbound TTS has a path) and tell the listener.
  def handle_info({:bind_connection, conn_id}, state) when is_binary(conn_id) do
    cond do
      state.conn_id == conn_id ->
        {:noreply, state}

      true ->
        case state.transport.attach(conn_id, self()) do
          :ok ->
            Registry.register(VoiceCore.CallRegistry, {:media, conn_id}, self())
            notify(state.listener, {:media_ready, conn_id})

            Logger.info("MediaSession #{state.call_id}: bound transport conn #{conn_id}",
              call_id: state.call_id
            )

            {:noreply, start_tx(%{state | conn_id: conn_id})}

          {:error, reason} ->
            Logger.warning(
              "MediaSession #{state.call_id}: bind failed (#{inspect(reason)})",
              call_id: state.call_id
            )

            {:noreply, state}
        end
    end
  end

  def handle_info({:audio_connected, transport_ref}, state) do
    Logger.info("MediaSession #{state.call_id}: media connected")

    cond do
      is_binary(transport_ref) -> {:noreply, %{state | conn_id: transport_ref}}
      true -> {:noreply, state}
    end
  end

  # Real-time outbound pacing: send 20 ms of queued audio, or silence when idle,
  # so the AudioSocket connection never goes idle (Asterisk drops it after 2 s).
  def handle_info(:tx_tick, %{conn_id: nil} = state) do
    {:noreply, %{state | tx_timer: nil}}
  end

  def handle_info(:tx_tick, state) do
    {chunk, rest} = next_tx_chunk(state.tx_queue)
    wire = encode_outbound(chunk, state.byte_order)

    case state.transport.send_audio(state.conn_id, wire) do
      :ok ->
        :telemetry.execute([:voice_core, :media, :tx], %{bytes: byte_size(wire)}, %{
          call_id: state.call_id
        })

      {:error, reason} ->
        Logger.debug("MediaSession #{state.call_id}: tx failed (#{inspect(reason)})",
          call_id: state.call_id
        )
    end

    timer = Process.send_after(self(), :tx_tick, @tx_tick_ms)

    {:noreply,
     %{state | tx_queue: rest, tx_timer: timer, audio_frames_tx: state.audio_frames_tx + 1}}
  end

  def handle_info(:media_disconnected, state) do
    Logger.info("MediaSession #{state.call_id}: media disconnected", call_id: state.call_id)
    notify(state.listener, :media_disconnected)
    {:noreply, %{state | conn_id: nil, tx_timer: cancel_tx(state.tx_timer)}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.tx_timer, do: Process.cancel_timer(state.tx_timer)

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

  defp notify(listener, message) when is_pid(listener), do: send(listener, message)
  defp notify(_listener, _message), do: :ok

  # ─── Outbound pacing ────────────────────────────────────────────────────────

  # Starts the real-time outbound ticker once (idempotent).
  defp start_tx(%{tx_timer: nil} = state) do
    %{state | tx_timer: Process.send_after(self(), :tx_tick, @tx_tick_ms)}
  end

  defp start_tx(state), do: state

  defp cancel_tx(nil), do: nil
  defp cancel_tx(ref), do: Process.cancel_timer(ref) && nil

  # One 20 ms frame: as much queued PCM as is available (padded with silence to a
  # whole frame), or pure silence when the queue is empty.
  defp next_tx_chunk(<<chunk::binary-size(@frame_bytes), rest::binary>>), do: {chunk, rest}

  defp next_tx_chunk(<<>>), do: {silence_20ms(), <<>>}

  defp next_tx_chunk(queue) do
    {queue <> silence_pad(@frame_bytes - byte_size(queue)), <<>>}
  end

  defp silence_20ms, do: :binary.copy(<<0::16>>, 160)

  defp silence_pad(bytes), do: :binary.copy(<<0>>, bytes)

  # A transport may declare its wire byte order via an optional `byte_order/0`
  # callback; transports that do not (tests, future adapters) are treated as
  # big-endian, i.e. identical to the internal representation (identity).
  defp transport_byte_order(transport) do
    case Code.ensure_loaded(transport) do
      {:module, _} ->
        if function_exported?(transport, :byte_order, 0), do: transport.byte_order(), else: :big

      _ ->
        :big
    end
  end

  # Inbound (wire → internal): little-endian wire becomes big-endian internal.
  defp decode_inbound(pcm, :little), do: VoiceCore.PCM.swap16(pcm)
  defp decode_inbound(pcm, _order), do: pcm

  # Outbound (internal → wire): big-endian internal becomes little-endian wire.
  defp encode_outbound(pcm, :little), do: VoiceCore.PCM.swap16(pcm)
  defp encode_outbound(pcm, _order), do: pcm
end
