defmodule VoiceCore.VoiceAgent.TurnTest do
  @moduledoc """
  Pure turn/endpointing state machine tests. No processes, no network.
  """

  use ExUnit.Case, async: true

  alias VoiceCore.VoiceAgent.Turn

  # 100 ms of 8 kHz 16-bit PCM at a given constant sample value (big-endian).
  defp frame(value, samples \\ 800) do
    :binary.copy(<<value::signed-big-16>>, samples)
  end

  defp new_turn(opts \\ []) do
    Turn.new(Keyword.merge([threshold: 300.0, silence_frames_to_endpoint: 3], opts))
  end

  describe "rms/2" do
    test "digital silence is zero" do
      assert Turn.rms(frame(0), :big) == 0.0
    end

    test "constant signal has rms equal to its magnitude" do
      assert_in_delta Turn.rms(frame(1000), :big), 1000.0, 0.001
    end

    test "little-endian decoding differs from big-endian" do
      little = <<0xE8, 0x03>>
      big = <<0x03, 0xE8>>
      assert Turn.rms(little, :little) == Turn.rms(big, :big)
    end

    test "odd trailing byte is ignored" do
      assert is_float(Turn.rms(frame(500) <> <<1>>, :big))
    end
  end

  describe "feed_frame/2" do
    test "silence while idle stays idle" do
      {turn, event} = Turn.feed_frame(new_turn(), frame(0))
      assert event == :none
      assert turn.state == :idle
    end

    test "energy above threshold starts an utterance" do
      {turn, event} = Turn.feed_frame(new_turn(), frame(1000))
      assert event == :speech_start
      assert turn.state == :listening
    end

    test "trailing silence past the threshold endpoints the utterance" do
      {turn, :speech_start} = Turn.feed_frame(new_turn(), frame(1000))

      {turn, :none} = Turn.feed_frame(turn, frame(0))
      {turn, :none} = Turn.feed_frame(turn, frame(0))
      {turn, event} = Turn.feed_frame(turn, frame(0))

      assert {:speech_end, pcm} = event
      assert byte_size(pcm) > 0
      assert turn.state == :idle
      assert turn.buffer == <<>>
    end

    test "speech during playback reports a barge-in (speech_start)" do
      turn = %{new_turn() | state: :speaking}
      {turn, event} = Turn.feed_frame(turn, frame(2000))
      assert event == :speech_start
      assert turn.state == :listening
    end

    test "silence during playback is ignored" do
      turn = %{new_turn() | state: :speaking}
      {turn, event} = Turn.feed_frame(turn, frame(0))
      assert event == :none
      assert turn.state == :speaking
    end

    test "frames shorter than one sample are ignored" do
      {turn, event} = Turn.feed_frame(new_turn(), <<1>>)
      assert event == :none
      assert turn.state == :idle
    end
  end
end
