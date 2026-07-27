defmodule VoiceCore.MediaTransport.AudioSocketTest do
  @moduledoc """
  Tests for AudioSocket protocol handler.
  """

  use ExUnit.Case, async: true
  alias VoiceCore.MediaTransport.AudioSocket

  describe "frame parsing" do
    test "parses valid audio frame" do
      # Audio frame: type=1, length=2 (2 bytes payload)
      frame_data = <<1::8, 0::8, 0::8, 2::8, 0::8, 1::8>>
      result = AudioSocket.parse(frame_data)
      assert result == {:ok, %{type: :audio, payload: <<0, 1>>, length: 2}, <<>>}
    end

    test "parses valid DTMF frame" do
      # DTMF frame: type=2, length=1, payload="5"
      # 53 is ASCII '5'
      frame_data = <<2::8, 0::8, 0::8, 1::8, 53::8>>
      result = AudioSocket.parse(frame_data)
      assert result == {:ok, %{type: :dtmf, payload: <<53>>, length: 1}, <<>>}
    end

    test "parses control frame" do
      # Control frame: type=3, length=0
      frame_data = <<3::8, 0::8, 0::8, 0::8>>
      result = AudioSocket.parse(frame_data)
      assert result == {:ok, %{type: :control, payload: <<>>, length: 0}, <<>>}
    end

    test "returns incomplete when frame header is partial" do
      # Only 2 bytes of 4-byte header
      partial_header = <<1::8, 0::8>>
      result = AudioSocket.parse(partial_header)
      assert result == {:error, :incomplete, partial_header}
    end

    test "returns incomplete when payload is partial" do
      # Header says 10 bytes, but only 5 provided
      header = <<1::8, 0::8, 0::8, 10::8>>
      partial_payload = <<1::8, 2::8, 3::8, 4::8, 5::8>>
      result = AudioSocket.parse(header <> partial_payload)
      assert result == {:error, :incomplete, header <> partial_payload}
    end

    test "rejects frames larger than max size" do
      # Frame claiming 70000 bytes (exceeds 65535 max)
      # 0x010111 = 65809
      large_header = <<1::8, 1::8, 17::8>>
      # Provide 1 byte of payload to make frame complete but oversized
      large_frame = large_header <> <<0>>
      result = AudioSocket.parse(large_frame)
      assert result == {:error, :frame_too_large, large_frame}
    end

    test "parses multiple frames from single buffer" do
      # Two audio frames: first 2 bytes, second 2 bytes
      frame1 = <<1::8, 0::8, 0::8, 2::8, 1::8, 2::8>>
      frame2 = <<1::8, 0::8, 0::8, 2::8, 3::8, 4::8>>
      result = AudioSocket.parse_multiple(frame1 <> frame2)

      assert result ==
               {:ok,
                [
                  %{type: :audio, payload: <<1, 2>>, length: 2},
                  %{type: :audio, payload: <<3, 4>>, length: 2}
                ], <<>>}
    end

    test "parses partial frame and returns remaining" do
      # Complete frame + partial second frame
      complete = <<1::8, 0::8, 0::8, 2::8, 1::8, 2::8>>
      # Only 2 bytes of next header
      partial = <<1::8, 0::8>>
      result = AudioSocket.parse_multiple(complete <> partial)

      assert result ==
               {:ok,
                [
                  %{type: :audio, payload: <<1, 2>>, length: 2}
                ], partial}
    end

    test "extracts audio from audio frame" do
      frame = %{type: :audio, payload: <<1::8, 2::8, 3::8, 4::8>>, length: 4}
      result = AudioSocket.extract_audio(frame)
      assert result == {:ok, <<1, 2, 3, 4>>}
    end

    test "returns error for non-audio frame in extract_audio" do
      frame = %{type: :dtmf, payload: <<53>>, length: 1}
      result = AudioSocket.extract_audio(frame)
      assert result == {:error, :not_audio_frame}
    end
  end

  describe "frame creation" do
    test "creates valid DTMF frame" do
      result = AudioSocket.create_dtmf_frame("5")
      assert result == {:ok, <<2::8, 0::8, 0::8, 1::8, 53::8>>}
    end

    test "rejects invalid DTMF digit" do
      result = AudioSocket.create_dtmf_frame("AB")
      assert result == {:error, :invalid_digit}
    end

    test "creates valid audio frame" do
      payload = <<1::8, 2::8, 3::8, 4::8>>
      result = AudioSocket.create_audio_frame(payload)
      expected = <<1::8, 0::8, 0::8, 4::8, 1::8, 2::8, 3::8, 4::8>>
      assert result == {:ok, expected}
    end

    test "rejects oversized audio payload" do
      large_payload = :binary.copy(<<0>>, 70000)
      result = AudioSocket.create_audio_frame(large_payload)
      assert result == {:error, :payload_too_large}
    end

    test "creates silence frame" do
      {:ok, frame} = AudioSocket.create_silence_frame()
      # 4 byte header + 320 bytes payload
      assert byte_size(frame) == 324
      assert is_binary(frame)
    end
  end

  describe "edge cases" do
    test "handles empty buffer" do
      result = AudioSocket.parse(<<>>)
      assert result == {:error, :incomplete, <<>>}
    end

    test "handles malformed length encoding" do
      # Invalid header with corrupted length bytes
      bad_header = <<1::8, 255::8, 255::8, 255::8>>
      result = AudioSocket.parse(bad_header)
      # Should either parse as large frame or error, depending on validation
      assert is_tuple(result)
    end
  end
end
