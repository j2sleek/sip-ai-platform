defmodule VoiceCore.VoiceAgent.Turn do
  @moduledoc """
  Pure turn/endpointing state machine. No timers, no processes, fully testable:

      * `:speech_start` — speech energy crossed the threshold (user began
        speaking; used for barge-in during playback),
      * `{:speech_end, pcm}` — trailing silence accumulated past
        `silence_ms_to_endpoint`; `pcm` is the recorded utterance ready for STT,
      * `:none` — nothing changed for this frame.

  End-of-speech is measured in **time**, not frames. The media transport may
  deliver 10/20/100 ms frames depending on the backend, so a frame count would
  make the endpoint window vary wildly (e.g. 6 frames is 120 ms on Asterisk's
  20 ms AudioSocket frames but 600 ms on 100 ms frames — the former cuts the
  caller off mid-sentence). `silence_ms_to_endpoint` (default 700 ms) and
  `min_speech_ms` (default 200 ms, so clicks/coughs are ignored) are
  frame-size independent.

  Energy-based VAD (RMS threshold) is deliberately lightweight and model-free;
  heavier neural VAD can replace it behind `VoiceCore.Vad` without touching this
  module (AGENTS.md rule 5 — providers behind an interface).
  """

  defstruct sample_rate: 8000,
            frame_samples: 800,
            threshold: 300.0,
            silence_ms_to_endpoint: 700,
            min_speech_ms: 200,
            endianness: :big,
            state: :idle,
            speech_seen: false,
            silence_ms: 0.0,
            speech_ms: 0.0,
            buffer: <<>>

  @type t :: %__MODULE__{}
  @type event :: :none | :speech_start | {:speech_end, binary()}

  @doc "Build a turn detector from agent config."
  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts), do: new(Map.new(opts))

  def new(opts) when is_map(opts) do
    %__MODULE__{
      sample_rate: Map.get(opts, :sample_rate, 8000),
      frame_samples: Map.get(opts, :frame_samples, 800),
      threshold: Map.get(opts, :vad_threshold, 300.0) |> to_float(),
      silence_ms_to_endpoint: Map.get(opts, :silence_ms_to_endpoint, 700) |> to_float(),
      min_speech_ms: Map.get(opts, :min_speech_ms, 200) |> to_float()
    }
  end

  @doc "Feed one frame of PCM; returns the updated detector and any turn event."
  @spec feed_frame(t(), binary()) :: {t(), event()}
  def feed_frame(turn, pcm) when is_binary(pcm) and byte_size(pcm) >= 2 do
    speech? = rms(pcm, turn.endianness) >= turn.threshold
    do_feed(turn, speech?, pcm)
  end

  def feed_frame(turn, _short_pcm), do: {turn, :none}

  # ─── internals ──────────────────────────────────────────────────────────────

  # Barge-in: the user spoke over playback.
  defp do_feed(%__MODULE__{state: :speaking} = turn, true, pcm) do
    {%{
       turn
       | state: :listening,
         speech_seen: true,
         silence_ms: 0.0,
         speech_ms: frame_ms(pcm, turn.sample_rate),
         buffer: pcm
     }, :speech_start}
  end

  defp do_feed(%__MODULE__{state: :speaking} = turn, false, _pcm), do: {turn, :none}

  defp do_feed(%__MODULE__{state: :listening} = turn, true, pcm) do
    turn = append(turn, pcm)

    %{turn | silence_ms: 0.0, speech_ms: turn.speech_ms + frame_ms(pcm, turn.sample_rate)}
    |> then(&{&1, :none})
  end

  defp do_feed(%__MODULE__{state: :listening} = turn, false, pcm) do
    turn = append(turn, pcm)
    silence_ms = turn.silence_ms + frame_ms(pcm, turn.sample_rate)

    cond do
      silence_ms < turn.silence_ms_to_endpoint ->
        {%{turn | silence_ms: silence_ms}, :none}

      turn.speech_ms < turn.min_speech_ms ->
        # Too short to be a real utterance (click/noise) — discard it.
        {reset(turn), :none}

      true ->
        utterance = turn.buffer
        {reset(turn), {:speech_end, utterance}}
    end
  end

  defp do_feed(%__MODULE__{state: :idle} = turn, true, pcm) do
    {%{
       turn
       | state: :listening,
         speech_seen: true,
         silence_ms: 0.0,
         speech_ms: frame_ms(pcm, turn.sample_rate),
         buffer: pcm
     }, :speech_start}
  end

  defp do_feed(turn, false, _pcm), do: {turn, :none}

  defp reset(turn) do
    %{
      turn
      | state: :idle,
        speech_seen: false,
        silence_ms: 0.0,
        speech_ms: 0.0,
        buffer: <<>>
    }
  end

  defp append(turn, pcm), do: %{turn | buffer: turn.buffer <> pcm}

  defp frame_ms(pcm, sample_rate) when sample_rate > 0 do
    div(byte_size(pcm), 2) * 1000.0 / sample_rate
  end

  @doc "RMS energy of a PCM frame (big- or little-endian 16-bit samples)."
  @spec rms(binary(), :big | :little) :: float()
  def rms(pcm, endianness) when byte_size(pcm) >= 2 do
    samples = decode(pcm, endianness, [])

    case samples do
      [] ->
        0.0

      _ ->
        sum = Enum.reduce(samples, 0, fn s, acc -> acc + s * s end)
        :math.sqrt(sum / length(samples))
    end
  end

  defp decode(<<>>, _endianness, acc), do: Enum.reverse(acc)
  defp decode(<<_byte::8>>, _endianness, acc), do: Enum.reverse(acc)

  defp decode(<<s::signed-16, rest::binary>>, :big, acc), do: decode(rest, :big, [s | acc])

  defp decode(<<s::signed-little-16, rest::binary>>, :little, acc),
    do: decode(rest, :little, [s | acc])

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(_other), do: 0.0
end
