defmodule VoiceCore.CallSessionTest do
  @moduledoc """
  Tests for CallSession.
  """

  use ExUnit.Case, async: true
  alias VoiceCore.CallSession

  describe "call session lifecycle" do
    test "creates new call session" do
      call_id = "test-call-123"
      caller_id = "1001"
      destination = "2000"

      callsession = CallSession.new(call_id, :pjsip, caller_id, destination)

      assert callsession.call_id == call_id
      assert callsession.state == :new
      assert callsession.source == :pjsip
      assert callsession.caller_id == caller_id
      assert callsession.destination == destination
      assert callsession.media_session == nil
    end

    test "transitions through states" do
      call_id = "test-call-456"
      callsession = CallSession.new(call_id, :pjsip, "1001", "2000")

      # Test state transitions
      connected = CallSession.connect(callsession)
      assert connected.state == :connected

      media_active = CallSession.media_active(connected)
      assert media_active.state == :media_active

      ending = CallSession.end_session(media_active)
      assert ending.state == :ending

      ended = CallSession.terminate(ending)
      assert ended.state == :ended
    end

    test "active? returns true for active states" do
      new_session = CallSession.new("test-789", :pjsip, "1001", "2000")
      assert CallSession.active?(new_session) == false

      connected = CallSession.connect(new_session)
      assert CallSession.active?(connected) == true

      media_active = CallSession.media_active(connected)
      assert CallSession.active?(media_active) == true

      ending = CallSession.end_session(media_active)
      assert CallSession.active?(ending) == false
    end

    test "ended? returns true for ended states" do
      session = CallSession.new("test-999", :pjsip, "1001", "2000")
      assert CallSession.ended?(session) == false

      ended = session |> CallSession.end_session() |> CallSession.terminate()
      assert CallSession.ended?(ended) == true
    end
  end

  describe "child exit handling" do
    test "a normal child exit does not end the call" do
      call_id = "testsess-normal-#{System.unique_integer([:positive])}"
      {:ok, pid} = CallSession.start_link(%{call_id: call_id})
      ref = Process.monitor(pid)

      media = :sys.get_state(pid).media_session
      assert is_pid(media)
      GenServer.stop(media, :normal)

      # Session survives and forgets the dead child.
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert Process.alive?(pid)
      assert :sys.get_state(pid).media_session == nil

      GenServer.stop(pid, :normal)
    end

    test "an abnormal media exit ends the session" do
      call_id = "testsess-abnormal-#{System.unique_integer([:positive])}"
      {:ok, pid} = CallSession.start_link(%{call_id: call_id})
      ref = Process.monitor(pid)

      media = :sys.get_state(pid).media_session
      Process.exit(media, :boom)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end
  end

  describe "outbound answer timing" do
    test "defers media setup until the channel state is Up" do
      call_id = "testsess-outbound-#{System.unique_integer([:positive])}"
      {:ok, pid} = CallSession.start_link(%{call_id: call_id})
      channel = %{"id" => "chan-#{System.unique_integer([:positive])}", "state" => "Ring"}

      send(
        pid,
        {:ari_event, %VoiceCore.ARI.Event.StasisStart{type: "StasisStart", channel: channel}}
      )

      # Synchronous round-trip guarantees the event has been handled.
      assert :sys.get_state(pid).media_setup == false

      # Answer arrives later → media is handed to AudioSocket once.
      send(
        pid,
        {:ari_event,
         %VoiceCore.ARI.Event.ChannelStateChange{
           type: "ChannelStateChange",
           channel: %{channel | "state" => "Up"}
         }}
      )

      assert :sys.get_state(pid).media_setup == true

      GenServer.stop(pid, :normal)
    end
  end
end
