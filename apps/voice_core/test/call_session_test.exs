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
end
