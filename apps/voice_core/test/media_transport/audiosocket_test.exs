defmodule VoiceCore.MediaTransport.AudioSocketTest do
  @moduledoc """
  Tests for the AudioSocket protocol codec (Asterisk `res_audiosocket` wire
  format: 1-byte kind + 2-byte big-endian length + payload).
  """

  use ExUnit.Case, async: true
  alias VoiceCore.MediaTransport.AudioSocket

  describe "frame parsing" do
    test "parses a valid audio frame (kind 0x10)" do
      frame_data = <<0x10, 0x00, 0x02, 0x00, 0x01>>
      result = AudioSocket.parse(frame_data)
      assert result == {:ok, %{type: :audio, payload: <<0, 1>>, length: 2}, <<>>}
    end

    test "parses a valid DTMF frame (kind 0x03)" do
      frame_data = <<0x03, 0x00, 0x01, 53>>
      result = AudioSocket.parse(frame_data)
      assert result == {:ok, %{type: :dtmf, payload: <<53>>, length: 1}, <<>>}
    end

    test "parses a UUID handshake frame (kind 0x01, 16 bytes)" do
      raw = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
      frame_data = <<0x01, 0x00, 0x10, raw::binary>>

      assert AudioSocket.parse(frame_data) ==
               {:ok, %{type: :uuid, payload: raw, length: 16}, <<>>}
    end

    test "parses a hangup frame (kind 0x00)" do
      assert AudioSocket.parse(<<0x00, 0x00, 0x00>>) ==
               {:ok, %{type: :hangup, payload: <<>>, length: 0}, <<>>}
    end

    test "returns incomplete when the header is partial" do
      partial_header = <<0x10, 0x00>>
      assert AudioSocket.parse(partial_header) == {:error, :incomplete, partial_header}
    end

    test "returns incomplete when the payload is partial" do
      header = <<0x10, 0x00, 0x0A>>
      partial_payload = <<1, 2, 3, 4, 5>>
      result = AudioSocket.parse(header <> partial_payload)
      assert result == {:error, :incomplete, header <> partial_payload}
    end

    test "parses multiple frames from a single buffer" do
      frame1 = <<0x10, 0x00, 0x02, 1, 2>>
      frame2 = <<0x10, 0x00, 0x02, 3, 4>>

      assert AudioSocket.parse_multiple(frame1 <> frame2) ==
               {:ok,
                [
                  %{type: :audio, payload: <<1, 2>>, length: 2},
                  %{type: :audio, payload: <<3, 4>>, length: 2}
                ], <<>>}
    end

    test "parses a partial frame and returns the remaining bytes" do
      complete = <<0x10, 0x00, 0x02, 1, 2>>
      partial = <<0x10, 0x00>>

      assert AudioSocket.parse_multiple(complete <> partial) ==
               {:ok, [%{type: :audio, payload: <<1, 2>>, length: 2}], partial}
    end

    test "extracts audio from an audio frame" do
      assert AudioSocket.extract_audio(%{type: :audio, payload: <<1, 2, 3, 4>>, length: 4}) ==
               {:ok, <<1, 2, 3, 4>>}
    end

    test "returns error for a non-audio frame in extract_audio" do
      assert AudioSocket.extract_audio(%{type: :dtmf, payload: <<53>>, length: 1}) ==
               {:error, :not_audio_frame}
    end
  end

  describe "frame creation" do
    test "creates a valid DTMF frame" do
      assert AudioSocket.create_dtmf_frame("5") == {:ok, <<0x03, 0x00, 0x01, 53>>}
    end

    test "rejects an invalid DTMF digit" do
      assert AudioSocket.create_dtmf_frame("AB") == {:error, :invalid_digit}
    end

    test "creates a valid audio frame (kind 0x10, 2-byte length)" do
      assert AudioSocket.create_audio_frame(<<1, 2, 3, 4>>) ==
               {:ok, <<0x10, 0x00, 0x04, 1, 2, 3, 4>>}
    end

    test "rejects an oversized audio payload" do
      large_payload = :binary.copy(<<0>>, 70_000)
      assert AudioSocket.create_audio_frame(large_payload) == {:error, :payload_too_large}
    end

    test "creates a hangup frame" do
      assert AudioSocket.create_hangup_frame() == {:ok, <<0x00, 0x00, 0x00>>}
    end

    test "creates the 16-byte UUID handshake frame" do
      uuid = "3f0c9a1e-2b7d-4c5a-9f1b-8e2d6a4c0b3a"
      assert {:ok, frame} = AudioSocket.create_uuid_frame(uuid)
      assert <<0x01, 0x00, 0x10, _raw::binary-size(16)>> = frame
      assert byte_size(frame) == 19
    end

    test "rejects a non-UUID for the handshake frame" do
      assert AudioSocket.create_uuid_frame("call-uuid-1") == {:error, :invalid_uuid}
    end

    test "creates a 20 ms silence frame" do
      {:ok, frame} = AudioSocket.create_silence_frame()
      # 3-byte header + 320 bytes payload
      assert byte_size(frame) == 323
    end
  end

  describe "UUID <-> raw bytes" do
    test "round-trips a standard UUID" do
      uuid = "3f0c9a1e-2b7d-4c5a-9f1b-8e2d6a4c0b3a"
      assert {:ok, raw} = AudioSocket.parse_uuid(uuid)
      assert byte_size(raw) == 16
      assert AudioSocket.format_uuid(raw) == uuid
    end

    test "rejects a non-standard UUID string" do
      assert AudioSocket.parse_uuid("PJSIP/1001-0000000a") == :error
      assert AudioSocket.parse_uuid("not-a-uuid") == :error
    end
  end

  describe "MediaTransport behaviour" do
    test "declares the audiosocket transport name" do
      assert AudioSocket.transport_name() == :audiosocket
    end

    test "declares little-endian wire byte order" do
      assert AudioSocket.byte_order() == :little
    end

    test "stats/0 delegates to the running AudioSocket server" do
      stats = AudioSocket.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :connections)
    end
  end
end
