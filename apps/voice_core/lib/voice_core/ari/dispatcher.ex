defmodule VoiceCore.ARI.Dispatcher do
  @moduledoc """
  Routes decoded ARI events to the owning `VoiceCore.CallSession`.

  On `StasisStart` for a channel with no session yet, a session is started
  (rule 6 — one isolated session per call). The call id is the ARI channel id
  when it is a UUID (control_api-originated calls set `channelId = call_id`, so
  media correlates automatically); otherwise a UUID is minted (inbound calls).

  Subsequent events (`ChannelStateChange`, `ChannelDestroyed`) are routed via the
  `{:channel, channel_id}` registry entry the session publishes on StasisStart.
  """

  require Logger

  alias VoiceCore.ARI.Event

  @doc "Dispatches one decoded ARI event. Returns `:ok` or `{:error, reason}`."
  @spec dispatch(struct()) :: :ok | {:error, term()}
  def dispatch(%Event.StasisStart{channel: %{"id" => channel_id}} = event) do
    case ensure_session(channel_id, event.channel) do
      {:ok, pid} ->
        send(pid, {:ari_event, event})
        :ok

      {:error, reason} ->
        Logger.warning("ARI: could not start session for #{channel_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def dispatch(%Event.ChannelStateChange{channel: %{"id" => channel_id}} = event) do
    route(channel_id, event)
  end

  def dispatch(%Event.ChannelDestroyed{channel: %{"id" => channel_id}} = event) do
    route(channel_id, event)
  end

  def dispatch(_event), do: :ok

  # ─── internals ──────────────────────────────────────────────────────────────

  defp route(channel_id, event) do
    case VoiceCore.CallRegistry.lookup_channel(channel_id) do
      {:ok, pid} ->
        send(pid, {:ari_event, event})
        :ok

      {:error, :not_found} ->
        Logger.debug("ARI event for unknown session: #{channel_id}")
        {:error, :no_session}
    end
  end

  defp ensure_session(channel_id, channel) do
    case VoiceCore.CallRegistry.lookup_channel(channel_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        call_id = VoiceCore.ARI.call_id(channel_id)

        case VoiceCore.CallSupervisor.start_call(call_id, %{
               source: :ari,
               channel_id: channel_id,
               caller_id: caller_number(channel),
               destination: channel_extension(channel)
             }) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp caller_number(channel), do: get_in(channel, ["caller", "number"]) || ""
  defp channel_extension(channel), do: get_in(channel, ["dialplan", "exten"]) || ""
end
