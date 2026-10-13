defmodule VoiceCore.VoiceAgent.Turn do
  @moduledoc """
  Pure turn-taking state machine for the voice agent body.

  Consumes 16-bit PCM frames and emits endpointing events with zero
  dependencies — no timers, no processes, fully testable:

      * `:speech_start` — speech energy crossed the threshold (user began
        speaking; used for barge-in during playback),
      * `{:speech_end, pcm}` — trailing silence accumulated past
        `silence_frames_to_endpoint`; `pcm` is the recorded utterance ready
        for STT,
      * `:none` — nothing changed for this frame.

  Energy-based VAD (RMS threshold) is deliberately lightweight and model-free;
  heavier neural VAD can replace it behind `VoiceCore.Vad` without touching this
  module (AGENTS.md rule 5 — providers behind an interface).
  """

  defstruct sample_rate: 8000,
            frame_samples: 800,
            threshold: 300.0,
            silence_frames_to_endpoint: 6,
            endianness: :big,
            state: :idle,
            speech_seen: false,
            silence_frames: 0,
            buffer: <<>>

  @type t :: %__MODULE__{}
  @type event :: :none | :speech_start | {:speech_end, binary()}

  @doc "Builds a turn tracker from agent config."
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      sample_rate: Map.get(opts, :sample_rate, 8000),
      frame_samples: Map.get(opts, :frame_samples, 800),
      threshold: Map.get(opts, :vad_threshold, 300.0) |> to_float(),
      silence_frames_to_endpoint: Map.get(opts, :silence_frames_to_endpoint, 6),
      endianness: Map.get(opts, :endianness, :big)
    }
  end

  @doc "Feeds one PCM frame (any size ≥ 2 bytes) and returns {turn, event}."
  @spec feed_frame(t(), binary()) :: {t(), event()}
  def feed_frame(turn, pcm) when byte_size(pcm) >= 2 do
    rms = rms(pcm, turn.endianness)
    speech? = rms >= turn.threshold
    do_feed(turn, speech?, pcm)
  end

  def feed_frame(turn, _short_pcm), do: {turn, :none}

  # ─── internals ──────────────────────────────────────────────────────────────

  defp do_feed(%__MODULE__{state: :speaking} = turn, true, pcm) do
    # User interrupted playback (barge-in): hand the live audio to the caller
    # as a fresh listening capture.
    {%{turn | state: :listening, speech_seen: true, silence_frames: 0, buffer: pcm},
     :speech_start}
  end

  defp do_feed(%__MODULE__{state: :speaking} = turn, false, _pcm) do
    {turn, :none}
  end

  defp do_feed(%__MODULE__{state: :listening} = turn, true, pcm) do
    {append(turn, pcm), :none}
  end

  defp do_feed(%__MODULE__{state: :listening} = turn, false, pcm) do
    case turn.silence_frames do
      frames when frames >= turn.silence_frames_to_endpoint - 1 ->
        # Enough trailing silence: end the utterance.
        utterance = turn.buffer <> pcm
        {reset(%{turn | state: :idle}), {:speech_end, utterance}}

      _ ->
        {append(%{turn | silence_frames: turn.silence_frames + 1}, pcm), :none}
    end
  end

  defp do_feed(%__MODULE__{state: :idle} = turn, true, pcm) do
    {append(%{turn | state: :listening, speech_seen: true, silence_frames: 0}, pcm),
     :speech_start}
  end

  defp do_feed(turn, false, _pcm), do: {turn, :none}

  defp append(turn, pcm), do: %{turn | buffer: turn.buffer <> pcm}

  defp reset(turn) do
    %{
      turn
      | state: :idle,
        speech_seen: false,
        silence_frames: 0,
        buffer: <<>>
    }
  end

  @doc "RMS of 16-bit PCM (big- or little-endian)."
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

  # Trailing odd byte (partial sample) — ignore it.
  defp decode(<<_byte::8>>, _endianness, acc), do: Enum.reverse(acc)

  defp decode(<<s::signed-16, rest::binary>>, :big, acc), do: decode(rest, :big, [s | acc])

  defp decode(<<s::signed-little-16, rest::binary>>, :little, acc),
    do: decode(rest, :little, [s | acc])

  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(_), do: 300.0
end
