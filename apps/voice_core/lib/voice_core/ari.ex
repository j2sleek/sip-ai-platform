defmodule VoiceCore.ARI do
  @moduledoc """
  ARI-facing helpers shared across the core.

  Asterisk's `AudioSocket` application requires the call routing key to be the
  *standard* string form of a UUID. Outbound calls are given their id by
  `control_api` (a `crypto.randomUUID()`), which already is one — so the ARI
  channel id *is* the call id and media correlates automatically. Inbound
  channels carry Asterisk channel ids (e.g. `PJSIP/1001-0000000a`), which are not
  UUIDs, so the core mints one here.

  See ADR-0010 and AGENTS.md rule 5 (no SIP/ARI internals leak into the agent).
  """

  import Bitwise

  @uuid_re ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @doc "True when `id` is the string form of a standard UUID (v4-shaped ok)."
  @spec uuid?(term()) :: boolean()
  def uuid?(id) when is_binary(id), do: Regex.match?(@uuid_re, id)
  def uuid?(_), do: false

  @doc """
  Normalises an ARI channel id into a call id usable as an AudioSocket UUID:
  returns the channel id unchanged when it is a UUID, otherwise a fresh v4 UUID.
  """
  @spec call_id(String.t()) :: String.t()
  def call_id(channel_id) when is_binary(channel_id) do
    if uuid?(channel_id), do: channel_id, else: new_uuid()
  end

  @doc "Generates a version-4 UUID string (lowercase)."
  @spec new_uuid() :: String.t()
  def new_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    Enum.join(
      [
        hex(<<a::32>>, 8),
        hex(<<b::16>>, 4),
        hex(<<c::16>>, 4),
        hex(<<d::16>>, 4),
        hex(<<e::48>>, 12)
      ],
      "-"
    )
  end

  defp hex(bin, _width), do: Base.encode16(bin, case: :lower)
end
