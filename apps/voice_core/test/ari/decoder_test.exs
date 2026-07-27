defmodule VoiceCore.ARI.DecoderTest do
  use ExUnit.Case, async: true
  alias VoiceCore.ARI.Decoder
  alias VoiceCore.ARI.Event

  test "decodes StasisStart" do
    json = ~S({"type": "StasisStart", "application": "voice_core", "channel": {"id": "123"}})

    assert {:ok, %Event.StasisStart{type: "StasisStart", channel: %{"id" => "123"}}} =
             Decoder.decode(json)
  end
end
