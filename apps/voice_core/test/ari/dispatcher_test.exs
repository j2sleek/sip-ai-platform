defmodule VoiceCore.ARI.DispatcherTest do
  use ExUnit.Case, async: true
  alias VoiceCore.ARI.Dispatcher
  alias VoiceCore.ARI.Event

  test "dispatches StasisStart" do
    event = %Event.StasisStart{type: "StasisStart", channel: %{"id" => "123"}}
    assert Dispatcher.dispatch(event) == {:error, :no_session}
  end
end
