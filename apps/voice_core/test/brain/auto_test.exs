defmodule VoiceCore.Brain.AutoTest do
  @moduledoc """
  Unit tests for the direction-aware brain (Layer 3, ADR-0017). Runs serially
  because it swaps the `:brain_local` application env.
  """

  use ExUnit.Case, async: false

  alias VoiceCore.Brain.Auto

  defmodule LocalEcho do
    @moduledoc false
    @behaviour VoiceCore.Brain
    @impl true
    def respond(text, _context, _timeout_ms), do: {:ok, "local:#{text}"}
  end

  setup do
    previous = Application.get_env(:voice_core, :brain_local)
    Application.put_env(:voice_core, :brain_local, LocalEcho)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:voice_core, :brain_local)
      else
        Application.put_env(:voice_core, :brain_local, previous)
      end
    end)
  end

  test "defers to the external brain when the call is bridged" do
    assert {:ok, ""} = Auto.respond("are you there?", %{call_id: "c", bridge: :attached}, 1_000)
  end

  test "answers with the local brain when the call is unbridged (inbound)" do
    assert {:ok, "local:hello"} =
             Auto.respond("hello", %{call_id: "c", bridge: :absent}, 1_000)
  end

  test "answers locally while the bridge status is still unknown" do
    assert {:ok, "local:hi"} = Auto.respond("hi", %{call_id: "c"}, 1_000)
  end
end
