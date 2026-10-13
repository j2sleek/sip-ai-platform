defmodule VoiceCore.MediaTransport.AudioSocket do
  @moduledoc """
  `VoiceCore.MediaTransport` adapter for the AudioSocket TCP protocol.

  Delegates to the `VoiceCore.AudioSocket.Server` connection registry: inbound
  PCM is routed by the server straight to the owning `VoiceCore.MediaSession`
  (see `VoiceCore.AudioSocket.Server` for call binding), and outbound PCM is
  framed and written by the per-connection process.

  Implements the Asterisk AudioSocket protocol (16-bit, 8 kHz, mono PCM);
  frame parsing/creation lives here so the wire format is testable in
  isolation (see the sibling tests).
  """

  @behaviour VoiceCore.MediaTransport

  alias VoiceCore.AudioSocket.Server

  @type frame_type :: :audio | :dtmf | :control | :unknown
  @type frame :: %{type: frame_type, payload: binary(), length: non_neg_integer()}

  # Maximum AudioSocket payload (3-byte length)
  @max_frame_size 65_535
  # Type (1 byte) + Length (3 bytes, big-endian)
  @header_size 4

  # ─── MediaTransport behaviour ───────────────────────────────────────────────

  @impl true
  def transport_name, do: :audiosocket

  @impl true
  def attach(conn_id, pid), do: Server.attach(conn_id, pid)

  @impl true
  def detach(conn_id), do: Server.detach(conn_id)

  @impl true
  def send_audio(conn_id, pcm), do: Server.send_audio(conn_id, pcm)

  @impl true
  def stats, do: Server.stats()

  # ─── Wire protocol (pure, testable) ─────────────────────────────────────────

  @doc """
  Parses one AudioSocket frame from a buffer. Returns
  `{:ok, frame, remaining}`, `{:error, :incomplete, buffer}` or
  `{:error, reason, buffer}`.
  """
  @spec parse(binary()) :: {:ok, frame, binary()} | {:error, atom(), binary()}
  def parse(buffer) when byte_size(buffer) >= @header_size do
    <<type::8, len1::8, len2::8, len3::8, rest::binary>> = buffer
    length = <<len1, len2, len3>> |> :binary.decode_unsigned()

    if byte_size(rest) >= length do
      <<payload::binary-size(^length), remaining::binary>> = rest

      {:ok,
       %{
         type: frame_type(type),
         payload: payload,
         length: length
       }, remaining}
    else
      if length > @max_frame_size do
        {:error, :frame_too_large, buffer}
      else
        {:error, :incomplete, buffer}
      end
    end
  rescue
    _ -> {:error, :invalid_frame, buffer}
  end

  def parse(buffer), do: {:error, :incomplete, buffer}

  @doc "Parses as many complete frames as the buffer holds."
  @spec parse_multiple(binary()) :: {:ok, [frame], binary()} | {:error, atom(), binary()}
  def parse_multiple(buffer), do: parse_multiple(buffer, [])

  defp parse_multiple(<<>>, frames), do: {:ok, Enum.reverse(frames), <<>>}

  defp parse_multiple(buffer, frames) do
    case parse(buffer) do
      {:ok, frame, remaining} -> parse_multiple(remaining, [frame | frames])
      {:error, :incomplete, remaining} -> {:ok, Enum.reverse(frames), remaining}
      {:error, reason, remaining} -> {:error, reason, remaining}
    end
  end

  @doc "Extracts the raw PCM payload from an audio frame."
  @spec extract_audio(frame) :: {:ok, binary()} | {:error, atom()}
  def extract_audio(%{type: :audio, payload: payload}), do: {:ok, payload}
  def extract_audio(%{type: _other}), do: {:error, :not_audio_frame}

  @doc "Creates an AudioSocket audio frame wrapping raw PCM."
  @spec create_audio_frame(binary()) :: {:ok, binary()} | {:error, atom()}
  def create_audio_frame(payload) do
    if byte_size(payload) > @max_frame_size do
      {:error, :payload_too_large}
    else
      {:ok, <<1::8, encode_length(byte_size(payload))::binary, payload::binary>>}
    end
  end

  @doc "Creates a DTMF frame for a single keypress digit."
  @spec create_dtmf_frame(String.t()) :: {:ok, binary()} | {:error, atom()}
  def create_dtmf_frame(digit) when byte_size(digit) == 1 do
    {:ok, <<2::8, 0::8, 0::8, 1::8, digit::binary>>}
  end

  def create_dtmf_frame(_digit), do: {:error, :invalid_digit}

  @doc "20 ms of digital silence (160 samples @ 8 kHz, 16-bit mono)."
  @spec create_silence_frame() :: {:ok, binary()} | {:error, atom()}
  def create_silence_frame do
    create_audio_frame(:binary.copy(<<0::size(16)>>, 160))
  end

  defp frame_type(1), do: :audio
  defp frame_type(2), do: :dtmf
  defp frame_type(3), do: :control
  defp frame_type(_), do: :unknown

  defp encode_length(length) when length <= @max_frame_size do
    <<byte1::8, byte2::8, byte3::8>> = <<length::24>>
    <<byte1, byte2, byte3>>
  end
end
