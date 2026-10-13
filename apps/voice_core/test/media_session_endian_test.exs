defmodule VoiceCore.MediaSessionEndianTest do
  @moduledoc """
  The AudioSocket wire format is little-endian 16-bit PCM while the core keeps
  PCM big-endian internally (TTS contract + turn detector). This pins the
  conversion `MediaSession` performs at the transport edge.
  """

  use ExUnit.Case, async: false

  alias VoiceCore.MediaSession

  defmodule LittleSinkTransport do
    @moduledoc false
    def byte_order, do: :little
    def attach(_conn_id, _pid), do: :ok
    def detach(_conn_id), do: :ok
    def stats, do: %{}

    def send_audio(_conn_id, pcm) do
      send(Process.whereis(:media_endian_sink), {:tx, pcm})
      :ok
    end
  end

  test "outbound is byte-swapped to little-endian and inbound back to big-endian" do
    Process.register(self(), :media_endian_sink)

    call_id = "endian-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MediaSession.start_link(%{
        call_id: call_id,
        transport: LittleSinkTransport,
        listener: self()
      })

    send(pid, {:bind_connection, "conn-1"})
    assert_receive {:media_ready, "conn-1"}, 1_000

    # internal big-endian <<1, 2>> → wire little-endian <<2, 1>> as the leading
    # sample of a 20 ms frame (the rest is silence padding).
    assert :ok = MediaSession.send_audio(pid, <<0x01, 0x02>>)
    assert_receive {:tx, <<0x02, 0x01, _::binary>>}, 1_000

    # inbound wire little-endian <<3, 4>> → internal big-endian <<4, 3>>
    send(pid, {:audio_frame_rx, <<0x03, 0x04>>})
    assert_receive {:audio, <<0x04, 0x03>>}, 1_000

    GenServer.stop(pid)
  end
end
