defmodule VoiceCore.MediaSessionTest do
  use ExUnit.Case, async: true
  alias VoiceCore.CallSession
  alias VoiceCore.CallRegistry

  test "media session starts with call session" do
    call_id = "test-call-media-#{System.unique_integer()}"

    {:ok, pid} =
      VoiceCore.CallSupervisor.start_call(call_id, %{
        source: :pjsip,
        caller_id: "1001",
        destination: "2000"
      })

    # Lookup call session
    {:ok, _call_pid} = CallRegistry.lookup(call_id)

    # Check if media session is registered
    media_call_id = {:media, call_id}
    assert {:ok, media_pid} = CallRegistry.lookup(media_call_id)
    assert is_pid(media_pid)
    assert Process.alive?(media_pid)

    # Cleanup
    VoiceCore.CallSupervisor.stop_call(pid)
  end
end
