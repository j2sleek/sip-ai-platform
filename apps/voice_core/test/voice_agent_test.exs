defmodule VoiceCore.VoiceAgentTest do
  @moduledoc """
  GenServer-level tests for the voice agent body, using an in-memory fake media
  sink and a fake AI client so the whole turn loop runs offline (no network,
  no models — see AGENTS.md testing rules).
  """

  use ExUnit.Case, async: true

  alias VoiceCore.VoiceAgent

  defmodule FakeMedia do
    @moduledoc false
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, [])
    def sent(pid), do: GenServer.call(pid, :sent)

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def handle_call({:send_audio, pcm}, _from, acc), do: {:reply, :ok, [pcm | acc]}
    def handle_call({:attach_transport, _conn_id}, _from, acc), do: {:reply, :ok, acc}
    def handle_call(:sent, _from, acc), do: {:reply, Enum.reverse(acc), acc}
    def handle_call(:stats, _from, acc), do: {:reply, %{chunks: length(acc)}, acc}
  end

  defmodule FakeAI do
    @moduledoc false
    # 100 ms of 8 kHz 16-bit PCM at a constant value.
    def transcribe(_pcm, _timeout), do: {:ok, "add barge-in support"}
    def synthesize(_text, timeout) when is_integer(timeout), do: {:ok, pcm()}
    defp pcm, do: :binary.copy(<<0, 120>>, 800)
  end

  defmodule FailingBrain do
    @moduledoc false
    @behaviour VoiceCore.Brain
    @impl true
    def respond(_t, _c, _timeout), do: {:error, :brain_unavailable}
  end

  # 100 ms of 8 kHz 16-bit PCM at a constant sample value (big-endian).
  defp frame(value, samples \\ 800), do: :binary.copy(<<value::signed-big-16>>, samples)

  defp await(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(20)
        do_await(fun, deadline)
      end
    end
  end

  defp start_agent do
    {:ok, media} = FakeMedia.start_link([])
    call_id = "agent-test-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: call_id,
        media_session: media,
        ai: FakeAI,
        brain: VoiceCore.Brain.Static
      })

    {agent, media}
  end

  test "starts idle" do
    {agent, _media} = start_agent()
    assert VoiceAgent.mode(agent) == :idle
    assert VoiceAgent.transcript(agent) == []
  end

  test "speech energy moves the agent to listening" do
    {agent, _media} = start_agent()
    send(agent, {:audio, frame(1000)})
    await(fn -> VoiceAgent.mode(agent) == :listening end)
  end

  test "an endpointed utterance flows through STT → brain → TTS playback" do
    {agent, media} = start_agent()

    # Speech, then enough trailing silence to endpoint the utterance.
    send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})

    await(fn -> VoiceAgent.mode(agent) == :idle and FakeMedia.sent(media) != [] end)

    chunks = FakeMedia.sent(media)
    assert chunks != []
    assert Enum.all?(chunks, &(byte_size(&1) > 0))

    # The transcript records the user utterance and the agent reply.
    entries = VoiceAgent.transcript(agent)
    assert [%{role: :user, text: user_text}, %{role: :agent, text: reply}] = entries
    assert user_text == "add barge-in support"
    assert reply =~ "add barge-in support"
  end

  test "brain errors return the agent to idle" do
    {:ok, media} = FakeMedia.start_link([])
    call_id = "agent-err-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: call_id,
        media_session: media,
        ai: FakeAI,
        brain: FailingBrain
      })

    send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})

    # STT succeeds (a user turn is recorded), the brain fails, and the agent
    # returns to idle without ever speaking.
    await(fn ->
      length(VoiceAgent.transcript(agent)) == 1 and VoiceAgent.mode(agent) == :idle
    end)

    assert FakeMedia.sent(media) == []
  end
end
