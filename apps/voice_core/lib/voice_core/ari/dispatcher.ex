defmodule VoiceCore.ARI.Dispatcher do
  require Logger

  def dispatch(%VoiceCore.ARI.Event.StasisStart{channel: %{"id" => channel_id}} = event) do
    Logger.debug("ARI event dispatched: StasisStart for #{channel_id}")
    route_to_session(channel_id, event)
  end

  def dispatch(%VoiceCore.ARI.Event.ChannelStateChange{channel: %{"id" => channel_id}} = event) do
    Logger.debug("ARI event dispatched: ChannelStateChange for #{channel_id}")
    route_to_session(channel_id, event)
  end

  def dispatch(%VoiceCore.ARI.Event.ChannelDestroyed{channel: %{"id" => channel_id}} = event) do
    Logger.debug("ARI event dispatched: ChannelDestroyed for #{channel_id}")
    route_to_session(channel_id, event)
  end

  def dispatch(_), do: :ok

  defp route_to_session(channel_id, event) do
    case VoiceCore.CallRegistry.lookup({:channel, channel_id}) do
      {:ok, pid} ->
        send(pid, {:ari_event, event})
        :ok

      {:error, :not_found} ->
        Logger.debug("ARI event dropped: no session for channel #{channel_id}")
        {:error, :no_session}
    end
  end
end
