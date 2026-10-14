defmodule VoiceCore.MediaSessionPacingTest do
  @moduledoc """
  The outbound pacer must stream at real time. A relative `send_after(20)` adds
  each tick's processing time to every interval, drifting ~8% slow — observed on
  a real Linphone call as a ~0.92 RTP clock ratio and a ~145 ms client jitter
  buffer. These tests pin the absolute-schedule behaviour and `flush/1`.
  """

  use ExUnit.Case, async: false

  alias VoiceCore.MediaSession

  defmodule PacingTransport do
    @moduledoc false
    def byte_order, do: :big
    def attach(_conn_id, _pid), do: :ok
    def detach(_conn_id), do: :ok
    def stats, do: %{}

    def send_audio(_conn_id, pcm) do
      # Emulate the real transport's synchronous socket send cost. Relative
      # scheduling adds this to every interval (drifting slow); the absolute
      # schedule compensates so the average cadence stays at 20 ms.
      Process.sleep(2)
      send(Process.whereis(:media_pacing_sink), {:tx, System.monotonic_time(:millisecond), pcm})
      :ok
    end
  end

  setup do
    Process.register(self(), :media_pacing_sink)
    call_id = "pacing-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MediaSession.start_link(%{call_id: call_id, transport: PacingTransport, listener: self()})

    :ok = MediaSession.attach_transport(pid, "conn-1")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{pid: pid}
  end

  test "outbound audio is paced at real time (no drift)", %{pid: pid} do
    # Two seconds of tone; the pacer splits it into 20 ms frames.
    :ok = MediaSession.send_audio(pid, :binary.copy(<<0x12, 0x34>>, 8000))

    stamps = collect_stamps(100)
    elapsed = List.last(stamps) - hd(stamps)

    # 99 gaps of 20 ms = 1980 ms. Relative scheduling adds the ~2 ms send cost
    # to every gap (≈2178 ms); the absolute schedule keeps ≈1980 ms. Allow
    # scheduler slack but reject systematic slowness/bursting.
    assert elapsed < 2_080, "pacing drifted slow: #{elapsed} ms over 99 frames"
    assert elapsed > 1_850, "pacing burst: #{elapsed} ms over 99 frames"
  end

  test "flush/1 drops queued playback so barge-in stops promptly", %{pid: pid} do
    # Two seconds of a clearly non-silent tone.
    :ok = MediaSession.send_audio(pid, :binary.copy(<<0x12, 0x34>>, 8000))

    # Let a few frames play, then simulate a barge-in.
    Process.sleep(60)
    :ok = MediaSession.flush(pid)
    Process.sleep(25)
    drain()

    Process.sleep(60)
    frames = collect_frames(3)

    assert frames != []
    assert Enum.all?(frames, &silent?/1), "flush left queued tone playing"
  end

  defp collect_stamps(n), do: collect_stamps(n, [])

  defp collect_stamps(0, acc), do: Enum.reverse(acc)

  defp collect_stamps(n, acc) do
    receive do
      {:tx, ms, _pcm} -> collect_stamps(n - 1, [ms | acc])
    after
      2_000 -> flunk("timed out waiting for outbound frames (got #{length(acc)})")
    end
  end

  defp collect_frames(n, acc \\ [])

  defp collect_frames(0, acc), do: Enum.reverse(acc)

  defp collect_frames(n, acc) do
    receive do
      {:tx, _ms, pcm} -> collect_frames(n - 1, [pcm | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  defp drain do
    receive do
      {:tx, _ms, _pcm} -> drain()
    after
      0 -> :ok
    end
  end

  defp silent?(pcm), do: pcm == :binary.copy(<<0>>, byte_size(pcm))
end
