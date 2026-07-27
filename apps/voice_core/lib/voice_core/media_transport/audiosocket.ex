defmodule VoiceCore.MediaTransport.AudioSocket do
  @moduledoc """
  AudioSocket protocol handler for bidirectional PCM audio transport.

  Implements the Asterisk AudioSocket protocol (16-bit, 8KHz, mono PCM).
  Handles frame parsing, audio payload extraction, and connection lifecycle.

  Protocol specification: https://docs.asterisk.org/Configuration/Channel-Driver/AudioSocket/
  """

  @type frame_type :: :audio | :dtmf | :control | :unknown
  @type frame :: %{type: frame_type, payload: binary, length: integer}

  @max_frame_size 65535  # Maximum payload size in bytes
  @header_size 4         # Type (1 byte) + Length (3 bytes)

  require Bitwise


  @doc """
  Parses AudioSocket frames from binary data.

  Handles partial frames, multiple frames, and buffering across TCP packets.

  Returns:
  - `{:ok, frame, remaining}` - Complete frame parsed, remaining data
  - `{:error, :incomplete, buffer}` - Need more data
  - `{:error, :invalid_frame, buffer}` - Malformed frame
  - `{:error, :frame_too_large, buffer}` - Frame exceeds max size
  """
  @spec parse(binary) ::
          {:ok, frame, binary} |
          {:error, atom, binary}
  def parse(buffer) when byte_size(buffer) >= @header_size do
    <<type::8, len1::8, len2::8, len3::8, rest::binary>> = buffer
    length = <<len1, len2, len3>> |> :binary.decode_unsigned()

    # Check if we have complete frame first
    if byte_size(rest) >= length do
      <<payload::binary-size(^length), remaining::binary>> = rest
      frame = %{
        type: frame_type(type),
        payload: payload,
        length: length
      }
      {:ok, frame, remaining}
    else
      # Validate frame length before declaring incomplete
      if length > @max_frame_size do
        {:error, :frame_too_large, buffer}
      else
        {:error, :incomplete, buffer}
      end
    end
  rescue
    _error ->
      {:error, :invalid_frame, buffer}
  end

  def parse(buffer) do
    {:error, :incomplete, buffer}
  end

  @doc """
  Extracts audio samples from an audio frame.

  Returns `{:ok, samples}` where samples is 16-bit signed PCM in network byte order,
  or `{:error, reason}` on failure.
  """
  @spec extract_audio(frame) :: {:ok, binary} | {:error, atom}
  def extract_audio(%{type: :audio, payload: payload}) do
    {:ok, payload}
  end
  def extract_audio(%{type: _other}) do
    {:error, :not_audio_frame}
  end

  @doc """
  Creates a DTMF frame for transmission.

  Returns `{:ok, binary}` containing the framed DTMF event,
  or `{:error, reason}` on failure.
  """
  @spec create_dtmf_frame(String.t()) :: {:ok, binary} | {:error, atom}
  def create_dtmf_frame(digit) when byte_size(digit) == 1 do
    # DTMF frame: type=2, length=1, payload=digit
    payload = digit
    length_bytes = <<0::8, 0::8, 1::8>>  # 1 byte length in 3 bytes (big-endian)
    frame = <<2::8, length_bytes::binary, payload::binary>>
    {:ok, frame}
  end
  def create_dtmf_frame(_digit) do
    {:error, :invalid_digit}
  end

  @doc """
  Creates an audio frame for transmission.

  Returns `{:ok, binary}` containing the framed audio payload,
  or `{:error, reason}` on failure.
  """
  @spec create_audio_frame(binary) :: {:ok, binary} | {:error, atom}
  def create_audio_frame(payload) do
    payload_size = byte_size(payload)

    # Validate payload size
    if payload_size > @max_frame_size do
      {:error, :payload_too_large}
    else
      # Audio frame: type=1, length=payload_size, payload
      length_bytes = encode_length(payload_size)
      frame = <<1::8, length_bytes::binary, payload::binary>>
      {:ok, frame}
    end
  end

  @doc """
  Creates a silence frame (20ms of silence at 8KHz, 16-bit mono).

  Returns `{:ok, binary}` containing the framed silence,
  or `{:error, reason}` on failure.
  """
  @spec create_silence_frame() :: {:ok, binary} | {:error, atom}
  def create_silence_frame do
    # 20ms at 8KHz = 160 samples, 16-bit = 320 bytes
    samples = 160
    payload = :binary.copy(<<0::size(16)>>, samples)
    create_audio_frame(payload)
  end

  @doc """
  Parses multiple frames from buffer.

  Continues parsing until buffer is exhausted or incomplete frame encountered.
  """
  @spec parse_multiple(binary) :: {:ok, [frame], binary} | {:error, atom, binary}
  def parse_multiple(buffer) do
    parse_multiple(buffer, [])
  end

  defp parse_multiple(<<>>, frames), do: {:ok, Enum.reverse(frames), <<>>}
  defp parse_multiple(buffer, frames) do
    case parse(buffer) do
      {:ok, frame, remaining} ->
        parse_multiple(remaining, [frame | frames])
      {:error, :incomplete, remaining} ->
        {:ok, Enum.reverse(frames), remaining}
      {:error, reason, remaining} ->
        {:error, reason, remaining}
    end
  end

  @doc """
  Converts frame type byte to atom.
  """
  defp frame_type(1), do: :audio
  defp frame_type(2), do: :dtmf
  defp frame_type(3), do: :control
  defp frame_type(_), do: :unknown

  @doc """
  Encodes length as 3-byte big-endian unsigned integer.
  """
  defp encode_length(length) when length <= @max_frame_size do
    # Encode as 3-byte big-endian using binary pattern matching
    <<byte1::8, byte2::8, byte3::8>> = <<length::24>>
    <<byte1, byte2, byte3>>
  end
end
