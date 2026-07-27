defmodule VoiceCore.MediaTransport.AudioSocketTest do
  @moduledoc """
  Tests for AudioSocket protocol handler.
  """

  use ExUnit.Case, async: true

  describe "frame parsing" do
    test "returns :not_implemented for unimplemented parse_frame" do
      result = VoiceCore.MediaTransport.AudioSocket.parse_frame(<<>>)
      assert result == {:error, :not_implemented}
    end

    test "returns :not_implemented for unimplemented extract_audio" do
      frame = %{type: :audio, payload: <<0::size(16)>>, uuid: "test"}
      result = VoiceCore.MediaTransport.AudioSocket.extract_audio(frame)
      assert result == {:error, :not_implemented}
    end

    test "returns :not_implemented for unimplemented create_dtmf_frame" do
      result = VoiceCore.MediaTransport.AudioSocket.create_dtmf_frame("1", "test-uuid")
      assert result == {:error, :not_implemented}
    end

    test "returns :not_implemented for unimplemented create_audio_frame" do
      result = VoiceCore.MediaTransport.AudioSocket.create_audio_frame(<<0::size(16)>>, "test-uuid")
      assert result == {:error, :not_implemented}
    end
  end
end
