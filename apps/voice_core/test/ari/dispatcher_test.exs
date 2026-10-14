defmodule VoiceCore.ARI.DispatcherTest do
  use ExUnit.Case, async: true
  alias VoiceCore.ARI.Dispatcher
  alias VoiceCore.ARI.Event

  describe "StasisStart" do
    test "starts an isolated session for a new channel and routes to it" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      event = %Event.StasisStart{type: "StasisStart", channel: %{"id" => channel_id}}

      assert :ok = Dispatcher.dispatch(event)
      assert {:ok, pid} = VoiceCore.CallRegistry.lookup_channel(channel_id)
      assert is_pid(pid)
      assert Process.alive?(pid)

      VoiceCore.CallSupervisor.stop_call(pid)
    end

    test "a non-UUID channel (dialled in) is an inbound call" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      event = %Event.StasisStart{type: "StasisStart", channel: %{"id" => channel_id}}

      assert :ok = Dispatcher.dispatch(event)
      assert {:ok, pid} = VoiceCore.CallRegistry.lookup_channel(channel_id)
      assert VoiceCore.CallSession.status(pid).direction == :inbound

      VoiceCore.CallSupervisor.stop_call(pid)
    end

    test "a UUID channel (ARI-originated by control_api) is outbound" do
      channel_id = VoiceCore.ARI.new_uuid()
      event = %Event.StasisStart{type: "StasisStart", channel: %{"id" => channel_id}}

      assert :ok = Dispatcher.dispatch(event)
      assert {:ok, pid} = VoiceCore.CallRegistry.lookup_channel(channel_id)
      assert VoiceCore.CallSession.status(pid).direction == :outbound

      VoiceCore.CallSupervisor.stop_call(pid)
    end
  end

  describe "routing for unknown channels" do
    test "ChannelStateChange is not routed" do
      event = %Event.ChannelStateChange{
        type: "ChannelStateChange",
        channel: %{"id" => "unknown-#{System.unique_integer([:positive])}"}
      }

      assert Dispatcher.dispatch(event) == {:error, :no_session}
    end

    test "ChannelDestroyed is not routed" do
      event = %Event.ChannelDestroyed{
        type: "ChannelDestroyed",
        channel: %{"id" => "unknown-#{System.unique_integer([:positive])}"}
      }

      assert Dispatcher.dispatch(event) == {:error, :no_session}
    end
  end
end
