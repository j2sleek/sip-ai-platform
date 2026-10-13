defmodule VoiceCore.AudioSocket.ServerTest do
  @moduledoc """
  Tests for the AudioSocket TCP server.

  The server is started by the OTP app on an ephemeral port in the test env
  (`config/test.exs`), so these exercise the real listener over loopback TCP:
  accept, attach, inbound audio routing, outbound framing, and stats.
  """

  use ExUnit.Case, async: false

  alias VoiceCore.AudioSocket.Server
  alias VoiceCore.MediaTransport.AudioSocket

  defp connect do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", Server.port(), [:binary, active: false, packet: :raw])

    socket
  end

  # Polls the server's connection map until a connection appears.
  defp await_conn(timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_conn(deadline)
  end

  defp do_await_conn(deadline) do
    case Map.keys(Server.connections()) do
      [conn_id | _] ->
        conn_id

      [] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("no AudioSocket connection registered before timeout")
        else
          Process.sleep(10)
          do_await_conn(deadline)
        end
    end
  end

  defp await_count(conn_id, key, min, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_count(conn_id, key, min, deadline)
  end

  defp do_await_count(conn_id, key, min, deadline) do
    value = Server.connections()[conn_id][key]

    if value >= min do
      value
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("connection #{key} did not reach #{min} (was #{value})")
      else
        Process.sleep(10)
        do_await_count(conn_id, key, min, deadline)
      end
    end
  end

  test "listens on a real port and accepts a connection" do
    assert Server.port() > 0
    socket = connect()
    conn_id = await_conn()
    assert is_binary(conn_id)
    :gen_tcp.close(socket)
  end

  test "routes inbound audio frames to the attached receiver" do
    socket = connect()
    conn_id = await_conn()

    # Attach *this* test process as the media receiver.
    assert :ok = Server.attach(conn_id, self())

    {:ok, frame} = AudioSocket.create_audio_frame(<<1, 2, 3, 4>>)
    :ok = :gen_tcp.send(socket, frame)

    assert_receive {:audio_frame_rx, <<1, 2, 3, 4>>}, 2_000
    :gen_tcp.close(socket)
  end

  test "counts orphan audio when no receiver is attached" do
    socket = connect()
    conn_id = await_conn()

    {:ok, frame} = AudioSocket.create_audio_frame(<<9, 9>>)
    :ok = :gen_tcp.send(socket, frame)

    assert await_count(conn_id, :orphan_frames, 1) >= 1
    :gen_tcp.close(socket)
  end

  test "writes outbound audio framed for the far end" do
    socket = connect()
    conn_id = await_conn()

    assert :ok = Server.send_audio(conn_id, <<7, 7, 7>>)
    assert {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    assert data == <<0x10::8, 0x00::8, 0x03::8, 7, 7, 7>>
    :gen_tcp.close(socket)
  end

  test "binds a connection via the UUID handshake frame (Asterisk flow)" do
    # A MediaSession would register {:media, uuid}; emulate the receiver here.
    uuid = VoiceCore.ARI.new_uuid()
    Registry.register(VoiceCore.CallRegistry, {:media, uuid}, self())

    socket = connect()
    _conn_id = await_conn()

    {:ok, handshake} = AudioSocket.create_uuid_frame(uuid)
    {:ok, audio} = AudioSocket.create_audio_frame(<<5, 5>>)
    :ok = :gen_tcp.send(socket, handshake <> audio)

    assert_receive {:audio_frame_rx, <<5, 5>>}, 2_000
    :gen_tcp.close(socket)
  end

  test "attach to an unknown connection fails cleanly" do
    assert Server.attach("does-not-exist", self()) == {:error, :unknown_connection}
  end

  test "reports aggregate stats" do
    stats = Server.stats()
    assert stats.host == "127.0.0.1"
    assert is_integer(stats.connections)
    assert is_integer(stats.accepted_total)
  end
end
