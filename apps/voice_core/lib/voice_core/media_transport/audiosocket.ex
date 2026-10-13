defmodule VoiceCore.MediaTransport.AudioSocket do
  @moduledoc """
  `VoiceCore.MediaTransport` adapter for the Asterisk AudioSocket protocol.

  Delegates to the `VoiceCore.AudioSocket.Server` connection registry: inbound
  PCM is routed by the server straight to the owning `VoiceCore.MediaSession`
  (see `VoiceCore.AudioSocket.Server` for call binding), and outbound PCM is
  framed and written by the per-connection process.

  Protocol (matches Asterisk `res_audiosocket` — 16-bit, 8 kHz, mono slin):

    * every message is `kind(1 byte)` + `length(2 bytes, big-endian)` + payload;
    * kinds: `0x00` hangup, `0x01` UUID, `0x03` DTMF, `0x10` audio,
      `0xff` error;
    * the first message Asterisk sends is a UUID message: kind `0x01`,
      length `0x10`, and the **16 raw UUID bytes** as payload;
    * audio payload is host-endian signed linear PCM (little-endian on this
      aarch64/x86_64 host) — see `byte_order/0`.

  Frame parsing/creation lives here so the wire format is testable in isolation.
  """

  @behaviour VoiceCore.MediaTransport

  alias VoiceCore.AudioSocket.Server

  @type frame_type :: :audio | :dtmf | :uuid | :hangup | :control | :unknown
  @type frame :: %{type: frame_type, payload: binary(), length: non_neg_integer()}

  # kind(1) + length(2, big-endian)
  @header_size 3
  @max_frame_size 65_535

  @kind_hangup 0x00
  @kind_uuid 0x01
  @kind_dtmf 0x03
  @kind_audio 0x10
  @kind_error 0xFF

  @uuid_re ~r/^([0-9a-fA-F]{8})-([0-9a-fA-F]{4})-([0-9a-fA-F]{4})-([0-9a-fA-F]{4})-([0-9a-fA-F]{12})$/

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

  @doc """
  AudioSocket carries host-endian signed linear PCM (little-endian on this
  host). The core keeps PCM big-endian internally, so `MediaSession` converts at
  this edge.
  """
  @spec byte_order() :: :little
  def byte_order, do: :little

  # ─── Wire protocol (pure, testable) ─────────────────────────────────────────

  @doc """
  Parses one AudioSocket frame from a buffer. Returns
  `{:ok, frame, remaining}` or `{:error, :incomplete, buffer}`.
  """
  @spec parse(binary()) :: {:ok, frame, binary()} | {:error, atom(), binary()}
  def parse(buffer) when byte_size(buffer) >= @header_size do
    <<kind::8, length::16, rest::binary>> = buffer

    if byte_size(rest) >= length do
      <<payload::binary-size(length), remaining::binary>> = rest
      {:ok, %{type: frame_type(kind), payload: payload, length: length}, remaining}
    else
      {:error, :incomplete, buffer}
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

  @doc "Creates an AudioSocket audio frame (kind `0x10`) wrapping raw PCM."
  @spec create_audio_frame(binary()) :: {:ok, binary()} | {:error, atom()}
  def create_audio_frame(payload) when is_binary(payload) do
    if byte_size(payload) > @max_frame_size do
      {:error, :payload_too_large}
    else
      {:ok, <<@kind_audio::8, byte_size(payload)::16, payload::binary>>}
    end
  end

  @doc "Creates a DTMF frame for a single keypress digit."
  @spec create_dtmf_frame(String.t()) :: {:ok, binary()} | {:error, atom()}
  def create_dtmf_frame(digit) when is_binary(digit) and byte_size(digit) == 1 do
    {:ok, <<@kind_dtmf::8, 1::16, digit::binary>>}
  end

  def create_dtmf_frame(_digit), do: {:error, :invalid_digit}

  @doc "Creates a hangup frame (kind `0x00`, empty payload)."
  @spec create_hangup_frame() :: {:ok, binary()}
  def create_hangup_frame, do: {:ok, <<@kind_hangup::8, 0::16>>}

  @doc """
  Creates the UUID handshake frame Asterisk sends first: kind `0x01`, length
  `0x10`, 16 raw bytes parsed from a standard UUID string.
  """
  @spec create_uuid_frame(String.t()) :: {:ok, binary()} | {:error, atom()}
  def create_uuid_frame(uuid) when is_binary(uuid) do
    case parse_uuid(uuid) do
      {:ok, raw} -> {:ok, <<@kind_uuid::8, 16::16, raw::binary>>}
      :error -> {:error, :invalid_uuid}
    end
  end

  @doc "Parses a standard UUID string into its 16 raw bytes."
  @spec parse_uuid(binary()) :: {:ok, <<_::128>>} | :error
  def parse_uuid(uuid) when is_binary(uuid) do
    case Regex.run(@uuid_re, uuid) do
      [_, a, b, c, d, e] ->
        {:ok,
         <<
           String.to_integer(a, 16)::32,
           String.to_integer(b, 16)::16,
           String.to_integer(c, 16)::16,
           String.to_integer(d, 16)::16,
           String.to_integer(e, 16)::48
         >>}

      _ ->
        :error
    end
  end

  @doc "Formats 16 raw UUID bytes as the standard lowercase string."
  @spec format_uuid(<<_::128>>) :: String.t()
  def format_uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    Enum.join(
      [hex(<<a::32>>), hex(<<b::16>>), hex(<<c::16>>), hex(<<d::16>>), hex(<<e::48>>)],
      "-"
    )
  end

  @doc "20 ms of digital silence (160 samples @ 8 kHz, 16-bit mono)."
  @spec create_silence_frame() :: {:ok, binary()} | {:error, atom()}
  def create_silence_frame do
    create_audio_frame(:binary.copy(<<0::size(16)>>, 160))
  end

  defp frame_type(@kind_audio), do: :audio
  defp frame_type(@kind_dtmf), do: :dtmf
  defp frame_type(@kind_uuid), do: :uuid
  defp frame_type(@kind_hangup), do: :hangup
  defp frame_type(@kind_error), do: :control
  defp frame_type(_), do: :unknown

  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
