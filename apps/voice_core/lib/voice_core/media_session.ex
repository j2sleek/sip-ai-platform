defmodule VoiceCore.MediaSession do
  @moduledoc """
  MediaSession handles the real-time media stream for a call.

  Responsibilities:
  - Associate media with a CallSession
  - Track AudioSocket connection
  - Track connection state
  - Count RX audio frames
  - Count TX audio frames
  - Track DTMF events
  - Handle connection lifecycle
  - Notify CallSession of important media events

  The MediaSession sits between the raw AudioSocket transport and the
  higher-level CallSession, providing a clean abstraction for audio handling.
  """

  use GenServer
  require Logger

  @moduledoc false

  def start_link(audiosocket_uuid, call_id) do
    GenServer.start_link(__MODULE__, {audiosocket_uuid, call_id}, name: via_tuple(audiosocket_uuid, call_id))
  end

  defp via_tuple(uuid, call_id) do
    {:via, __MODULE__, {uuid, call_id}}
  end

  @impl true
  def init({audiosocket_uuid, call_id}) do
    Logger.info("MediaSession starting for call #{call_id} with AudioSocket #{audiosocket_uuid}")

    state = %{
      audiosocket_uuid: audiosocket_uuid,
      call_id: call_id,
      connected_at: NaiveDateTime.utc_now(),
      audio_frames: 0,
      dtmf_events: []
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:audio_frame, frame}, state) do
    Logger.debug("MediaSession #{state.call_id}: audio frame received")
    {:noreply, %{state | audio_frames: state.audio_frames + 1}}
  end

  @impl true
  def handle_info({:dtmf_frame, digit}, state) do
    Logger.debug("MediaSession #{state.call_id}: DTMF digit '#{digit}' received")
    dtmf_events = [digit | state.dtmf_events]
    {:noreply, %{state | dtmf_events: dtmf_events}}
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
