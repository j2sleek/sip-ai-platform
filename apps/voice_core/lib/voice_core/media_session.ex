defmodule VoiceCore.MediaSession do
  @moduledoc """
  MediaSession handles the real-time media stream for a call.
  """

  use GenServer
  require Logger

  # --- API ---

  def start_link(args) do
    call_id = Map.fetch!(args, :call_id)
    GenServer.start_link(__MODULE__, args, name: via_tuple(call_id))
  end

  defp via_tuple(call_id) do
    {:via, Registry, {VoiceCore.CallRegistry, {:media, call_id}}}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(args) do
    call_id = Map.fetch!(args, :call_id)
    Logger.info("MediaSession starting for call #{call_id}")

    state = %{
      call_id: call_id,
      connected_at: NaiveDateTime.utc_now(),
      audio_frames_rx: 0,
      audio_frames_tx: 0,
      dtmf_events: []
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:audio_frame_rx, _frame}, state) do
    {:noreply, %{state | audio_frames_rx: state.audio_frames_rx + 1}}
  end

  @impl true
  def handle_info({:dtmf_frame, digit}, state) do
    Logger.debug("MediaSession #{state.call_id}: DTMF digit '#{digit}' received")
    {:noreply, %{state | dtmf_events: [digit | state.dtmf_events]}}
  end

  @impl true
  def handle_info(:media_connected, state) do
    Logger.info("MediaSession #{state.call_id}: media connected")
    {:noreply, state}
  end

  @impl true
  def handle_info(:media_disconnected, state) do
    Logger.info("MediaSession #{state.call_id}: media disconnected")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("MediaSession #{state.call_id}: terminating")
    :ok
  end
end
