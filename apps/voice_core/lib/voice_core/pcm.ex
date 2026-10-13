defmodule VoiceCore.PCM do
  @moduledoc """
  Byte-order helpers for 16-bit signed linear PCM.

  The core keeps PCM **big-endian** internally (matching the Python TTS contract
  and the turn detector). External boundaries are little-endian — the
  AudioSocket wire format (host `slin` on this host) and the Python STT service
  (WAV/`audio/pcm`) — so conversion happens there and only there. Keeping one
  implementation avoids the classic silent "garbled audio" class of bug.
  """

  @doc """
  Swaps the 16-bit sample byte order. A trailing odd byte (a truncated sample)
  is preserved rather than dropped, so malformed input can never crash the core.
  """
  @spec swap16(binary()) :: binary()
  def swap16(<<a, b, rest::binary>>), do: <<b, a, swap16(rest)::binary>>
  def swap16(<<odd>>), do: <<odd>>
  def swap16(<<>>), do: <<>>
end
