defmodule VoiceCore.ARI.DecoderTest do
  use ExUnit.Case, async: true
  alias VoiceCore.ARI.Decoder
  alias VoiceCore.ARI.Event

  test "decodes StasisStart" do
    json = ~S({"type": "StasisStart", "application": "voice_core", "channel": {"id": "123"}})

    assert {:ok, %Event.StasisStart{type: "StasisStart", channel: %{"id" => "123"}}} =
             Decoder.decode(json)
  end

  test "ignores event types the core does not act on (keeps the stream alive)" do
    json =
      ~s({"type":"ChannelVarset","channel":{"id":"123"},"variable":"AI_UUID","value":"abc"})

    assert Decoder.decode(json) == {:ignore, "ChannelVarset"}
  end

  test "returns a plain error for invalid JSON" do
    assert Decoder.decode("not json") == {:error, :invalid_json}
  end
end
