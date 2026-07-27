defmodule VoiceCore.CallSession do
  @moduledoc """
  Manages an individual call session.
  """

  use GenServer
  require Logger

  # State: :new, :ringing, :answered, :active, :ending, :ended
  defstruct [
    :call_id,
    :caller_id,
    :destination,
    :source,
    :state,
    :media_session,
    :start_time,
    :channel_id,
    :channel_state,
    :last_event_time
  ]

  # --- Struct API (Pure Functions for Testing) ---

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

  def connect(session), do: %{session | state: :connected}
  def media_active(session), do: %{session | state: :media_active}
  def end_session(session), do: %{session | state: :ending}
  def terminate(session), do: %{session | state: :ended}

  def active?(session), do: session.state in [:active, :connected, :media_active]
  def ended?(session), do: session.state == :ended

  # --- ARI Event Handler ---

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

    # Register for channel lookups
    VoiceCore.CallRegistry.register_channel(channel_id, self())

    new_state = %{
      state
      | channel_id: channel_id,
        channel_state: "StasisStart",
        last_event_time: System.system_time(:millisecond)
    }

    {:noreply, new_state}
  end

  defp handle_ari_event(%VoiceCore.ARI.Event.ChannelStateChange{channel: channel} = _event, state) do
    Logger.debug("ARI ChannelStateChange: #{channel["id"]}", call_id: state.call_id)

    new_state = %{
      state
      | channel_state: channel["state"],
        last_event_time: System.system_time(:millisecond)
    }

    {:noreply, new_state}
  end

  defp handle_ari_event(%VoiceCore.ARI.Event.ChannelDestroyed{} = _event, state) do
    Logger.info("ARI ChannelDestroyed: #{state.channel_id}", call_id: state.call_id)

    # Cleanup channel registry
    if state.channel_id, do: VoiceCore.CallRegistry.unregister_channel(state.channel_id)

    new_state = %{state | state: :ended, last_event_time: System.system_time(:millisecond)}
    {:stop, :normal, new_state}
  end

  defp handle_ari_event(event, state) do
    Logger.warning("ARI Unknown Event: #{event.type}", call_id: state.call_id)
    {:noreply, state}
  end

  def start_link(args) do
    call_id = Map.fetch!(args, :call_id)
    GenServer.start_link(__MODULE__, args, name: via_tuple(call_id))
  end

  @impl true
  def init(args) do
    call_id = Map.fetch!(args, :call_id)
    Logger.info("CallSession started for #{call_id}")

    # Start MediaSession
    {:ok, media_pid} = VoiceCore.MediaSession.start_link(%{call_id: call_id})

    state =
      new(call_id, Map.get(args, :source), Map.get(args, :caller_id), Map.get(args, :destination))

    {:ok, %{state | media_session: media_pid}}
  end

  defp via_tuple(call_id) do
    {:via, Registry, {VoiceCore.CallRegistry, call_id}}
  end
end
