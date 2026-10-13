defmodule VoiceCore.CallSession do
  @moduledoc """
  `VoiceCore.CallSession` is the supervised process for one call — the unit of
  isolation (AGENTS.md rule 6). It owns the call's `VoiceCore.MediaSession`
  (media I/O behind `MediaTransport`) and `VoiceCore.VoiceAgent` (turn-taking +
  brain), tracks ARI channel state, and cleans up deterministically on hangup.

  ARI events are dispatched here by `VoiceCore.ARI.Dispatcher` via the channel
  registry; media frames are routed by the transport directly to the
  `MediaSession`, which forwards audio to the `VoiceAgent`.

  Lifecycle: created through `VoiceCore.CallSupervisor.start_call/2`, terminated
  on `ChannelDestroyed` or explicit `hangup/1`.
  """

  use GenServer
  require Logger

  # ─── Pure state model (testable) ────────────────────────────────────────────

  # State: :new, :connected, :media_active, :ending, :ended
  defstruct [
    :call_id,
    :caller_id,
    :destination,
    :source,
    :state,
    :media_session,
    :voice_agent,
    :start_time,
    :channel_id,
    :channel_state,
    :last_event_time
  ]

  @type t :: %__MODULE__{}
  @type state :: :new | :connected | :media_active | :ending | :ended

  @spec new(String.t(), atom(), String.t(), String.t()) :: t()
  def new(call_id, source, caller_id, destination) do
    %__MODULE__{
      call_id: call_id,
      source: source,
      caller_id: caller_id,
      destination: destination,
      state: :new,
      start_time: System.system_time(:millisecond),
      last_event_time: System.system_time(:millisecond)
    }
  end

  @spec connect(t()) :: t()
  def connect(session), do: %{session | state: :connected}

  @spec media_active(t()) :: t()
  def media_active(session), do: %{session | state: :media_active}

  @spec end_session(t()) :: t()
  def end_session(session), do: %{session | state: :ending}

  @spec terminate(t()) :: t()
  def terminate(session), do: %{session | state: :ended}

  @spec active?(t()) :: boolean()
  def active?(session), do: session.state in [:active, :connected, :media_active]

  @spec ended?(t()) :: boolean()
  def ended?(session), do: session.state == :ended

  # ─── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) do
    call_id = Map.fetch!(args, :call_id)
    GenServer.start_link(__MODULE__, args, name: via_tuple(call_id))
  end

  @doc "Bind an AudioSocket connection id to this call's media session."
  @spec attach_media(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def attach_media(pid_or_name, conn_id) do
    GenServer.call(pid_or_name, {:attach_media, conn_id}, 10_000)
  end

  @doc "Request hangup — ends the session and stops child processes."
  @spec hangup(GenServer.server()) :: :ok
  def hangup(pid_or_name) do
    GenServer.call(pid_or_name, :hangup, 10_000)
  end

  @doc "Current call state."
  @spec status(GenServer.server()) :: map()
  def status(pid_or_name) do
    GenServer.call(pid_or_name, :status, 5_000)
  end

  defp via_tuple(call_id) do
    {:via, Registry, {VoiceCore.CallRegistry, call_id}}
  end

  # ─── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    call_id = Map.fetch!(args, :call_id)

    # Media + agent children belong to *this* session; when the session stops
    # they stop too (no orphaned processes — cleanup rule).
    {:ok, media_pid} =
      VoiceCore.MediaSession.start_link(%{
        call_id: call_id,
        listener: self()
      })

    {:ok, agent_pid} =
      VoiceCore.VoiceAgent.start_link(%{
        call_id: call_id,
        media_session: media_pid,
        brain: Map.get(args, :brain, VoiceCore.Brain.Static),
        ai: Map.get(args, :ai, VoiceCore.AI)
      })

    state =
      new(
        call_id,
        Map.get(args, :source, :unknown),
        Map.get(args, :caller_id, ""),
        Map.get(args, :destination, "")
      )

    Logger.info("CallSession started for call #{call_id}", call_id: call_id)
    {:ok, %{state | media_session: media_pid, voice_agent: agent_pid}}
  end

  @impl true
  def handle_call({:attach_media, conn_id}, _from, state) do
    case VoiceCore.MediaSession.attach_transport(state.media_session, conn_id) do
      :ok ->
        # The transport routes audio for this conn to the media session, which
        # forwards it to the voice agent. Mark the call media-active.
        Logger.info("CallSession #{state.call_id}: media attached (#{conn_id})",
          call_id: state.call_id
        )

        {:reply, :ok, %{state | channel_state: "media_active", state: :media_active}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:hangup, _from, state) do
    Logger.info("CallSession #{state.call_id}: hangup requested", call_id: state.call_id)
    {:stop, :normal, :ok, %{state | state: :ending}}
  end

  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  # Inbound audio from MediaSession → forward to the voice agent (the media
  # listen path is event-driven, never blocking).
  def handle_info({:audio, pcm}, state) do
    if is_pid(state.voice_agent), do: send(state.voice_agent, {:audio, pcm})
    {:noreply, state}
  end

  def handle_info({:dtmf, digit}, state) do
    if is_pid(state.voice_agent), do: send(state.voice_agent, {:dtmf, digit})
    {:noreply, state}
  end

  @impl true
  def handle_info({:ari_event, event}, state) do
    :telemetry.execute([:voice_core, :call_session, :ari_event], %{type: event.type}, %{
      call_id: state.call_id
    })

    handle_ari_event(event, state)
  end

  defp handle_ari_event(%VoiceCore.ARI.Event.StasisStart{channel: channel} = _event, state) do
    channel_id = channel["id"]
    Logger.info("ARI StasisStart: #{channel_id}", call_id: state.call_id)
    VoiceCore.CallRegistry.register_channel(channel_id, self())

    {:noreply,
     %{
       state
       | channel_id: channel_id,
         channel_state: "StasisStart",
         state: :connected,
         last_event_time: System.system_time(:millisecond)
     }}
  end

  defp handle_ari_event(%VoiceCore.ARI.Event.ChannelStateChange{channel: channel} = _event, state) do
    Logger.debug("ARI ChannelStateChange: #{channel["id"]}", call_id: state.call_id)

    {:noreply,
     %{
       state
       | channel_state: channel["state"],
         last_event_time: System.system_time(:millisecond)
     }}
  end

  defp handle_ari_event(%VoiceCore.ARI.Event.ChannelDestroyed{} = _event, state) do
    Logger.info("ARI ChannelDestroyed: #{state.channel_id}", call_id: state.call_id)

    if state.channel_id do
      VoiceCore.CallRegistry.unregister_channel(state.channel_id)
    end

    {:stop, :normal, %{state | state: :ended, last_event_time: System.system_time(:millisecond)}}
  end

  defp handle_ari_event(event, state) do
    Logger.warning("ARI Unknown Event: #{event.type}", call_id: state.call_id)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Children are linked; this log + registry cleanup is the deterministic
    # cleanup path.
    if state.channel_id do
      VoiceCore.CallRegistry.unregister_channel(state.channel_id)
    end

    Logger.info("CallSession #{state.call_id}: terminating (#{state.state})",
      call_id: state.call_id
    )

    :ok
  end

  defp status_map(state) do
    %{
      call_id: state.call_id,
      state: state.state,
      caller_id: state.caller_id,
      destination: state.destination,
      channel_id: state.channel_id,
      channel_state: state.channel_state,
      start_time: state.start_time,
      last_event_time: state.last_event_time
    }
  end
end
