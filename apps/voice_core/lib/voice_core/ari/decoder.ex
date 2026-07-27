defmodule VoiceCore.ARI.Decoder do
  require Logger
  alias VoiceCore.ARI.Event

  def decode(json) do
    with {:ok, data} <- Jason.decode(json),
         {:ok, type} <- Map.fetch(data, "type") do
      do_decode(type, data)
    else
      _ -> {:error, :invalid_json}
    end
  end

  defp do_decode("StasisStart", data) do
    {:ok,
     %Event.StasisStart{
       type: "StasisStart",
       application: data["application"],
       timestamp: data["timestamp"],
       channel: data["channel"],
       args: data["args"]
     }}
  end

  defp do_decode("ChannelStateChange", data) do
    {:ok,
     %Event.ChannelStateChange{
       type: "ChannelStateChange",
       application: data["application"],
       timestamp: data["timestamp"],
       channel: data["channel"]
     }}
  end

  defp do_decode("ChannelDestroyed", data) do
    {:ok,
     %Event.ChannelDestroyed{
       type: "ChannelDestroyed",
       application: data["application"],
       timestamp: data["timestamp"],
       channel: data["channel"],
       cause: data["cause"]
     }}
  end

  defp do_decode(type, _data), do: {:error, :unknown_event, type}
end
