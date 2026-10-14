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
    def flushes(pid), do: GenServer.call(pid, :flushes)

    @impl true
    def init(_), do: {:ok, %{sent: [], flushes: 0}}

    @impl true
    def handle_call({:send_audio, pcm}, _from, acc),
      do: {:reply, :ok, %{acc | sent: [pcm | acc.sent]}}

    def handle_call({:attach_transport, _conn_id}, _from, acc), do: {:reply, :ok, acc}
    def handle_call(:flush, _from, acc), do: {:reply, :ok, %{acc | flushes: acc.flushes + 1}}
    def handle_call(:sent, _from, acc), do: {:reply, Enum.reverse(acc.sent), acc}
    def handle_call(:flushes, _from, acc), do: {:reply, acc.flushes, acc}
    def handle_call(:stats, _from, acc), do: {:reply, %{chunks: length(acc.sent)}, acc}
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

  defmodule SilentBrain do
    @moduledoc false
    # A deferring brain (like `External`, or `Auto` on a bridged call): never
    # says anything locally, so the body waits for the bridge.
    @behaviour VoiceCore.Brain
    @impl true
    def respond(_t, _c, _timeout), do: {:ok, ""}
  end

  defmodule SlowAI do
    @moduledoc false
    # Transcribes instantly but never finishes synthesis during the test, so the
    # agent stays in :speaking with a pending (or replaced) playback watchdog.
    def transcribe(_pcm, _timeout), do: {:ok, "hello"}

    def synthesize(_text, _timeout) do
      Process.sleep(30_000)
      {:ok, :binary.copy(<<0, 120>>, 800)}
    end
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

    # Speech (>= min_speech_ms), then enough trailing silence to endpoint.
    for _ <- 1..3, do: send(agent, {:audio, frame(1000)})
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
    send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})

    # STT succeeds (a user turn is recorded), the brain fails, and the agent
    # returns to idle without ever speaking.
    await(fn ->
      length(VoiceAgent.transcript(agent)) == 1 and VoiceAgent.mode(agent) == :idle
    end)

    assert FakeMedia.sent(media) == []
  end

  test "barge-in during playback flushes queued audio and returns to listening" do
    {agent, media} = start_agent()

    # Drive a full turn so the agent enters :speaking.
    send(agent, {:audio, frame(1000)})
    send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})
    await(fn -> VoiceAgent.mode(agent) == :speaking end)

    before = FakeMedia.flushes(media)

    # Caller talks over the agent: a barge-in must flush queued playback.
    send(agent, {:audio, frame(2000)})
    await(fn -> VoiceAgent.mode(agent) == :listening end)

    assert FakeMedia.flushes(media) > before
  end

  test "back-to-back speak instructions never corrupt the playback timer" do
    # Regression: `start_speaking/2` used to store the return value of
    # `cancel_timer/1` (an integer or `:ok`) in `playback_timer`; the next
    # `cancel_timer` then raised `ArgumentError: not a reference`, killing the
    # agent (and the call) on the next barge-in/terminate.
    {:ok, media} = FakeMedia.start_link([])

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: "agent-timer-#{System.unique_integer([:positive, :monotonic])}",
        media_session: media,
        ai: SlowAI,
        brain: VoiceCore.Brain.Static
      })

    send(agent, {:speak, "first"})
    send(agent, {:speak, "second"})
    send(agent, {:speak, "third"})

    assert Process.alive?(agent)
    assert VoiceAgent.mode(agent) == :speaking
  end

  test "an external (MCP) brain records the caller turn but never speaks locally" do
    {:ok, media} = FakeMedia.start_link([])

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: "agent-ext-#{System.unique_integer([:positive, :monotonic])}",
        media_session: media,
        ai: FakeAI,
        brain: VoiceCore.Brain.External
      })

    for _ <- 1..3, do: send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})

    # The body transcribes + records the caller, then stands down (idle) without
    # synthesizing anything — the bridge owns what to say.
    await(fn -> length(VoiceAgent.transcript(agent)) == 1 and VoiceAgent.mode(agent) == :idle end)
    assert FakeMedia.sent(media) == []

    # The bridge (OpenCode) can now speak on the same call.
    send(agent, {:speak, "Hello from OpenCode"})
    await(fn -> VoiceAgent.mode(agent) == :speaking end)

    assert Enum.any?(
             VoiceAgent.transcript(agent),
             &(&1.role == :agent and &1.text == "Hello from OpenCode")
           )
  end

  test "a stale (superseded) turn's reply is dropped" do
    {agent, media} = start_agent()

    # A reply tagged with a turn that is no longer current must be ignored.
    send(agent, {:agent_reply, 9_999, {:ok, "stale reply"}})
    send(agent, {:utterance, 9_999, "stale utterance"})
    Process.sleep(50)

    assert VoiceAgent.mode(agent) == :idle
    assert VoiceAgent.transcript(agent) == []
    assert FakeMedia.sent(media) == []
  end

  test "spoken replies are clamped to max_reply_chars on a word boundary" do
    {:ok, media} = FakeMedia.start_link([])

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: "agent-clamp-#{System.unique_integer([:positive, :monotonic])}",
        media_session: media,
        ai: FakeAI,
        brain: VoiceCore.Brain.Static,
        max_reply_chars: 40
      })

    long =
      "This first sentence is already far too long to be spoken in one breath. " <>
        "A second sentence follows."

    send(agent, {:speak, long})
    await(fn -> VoiceAgent.transcript(agent) != [] end)

    assert [%{role: :agent, text: spoken}] = VoiceAgent.transcript(agent)
    assert String.length(spoken) <= 40
    assert String.starts_with?(spoken, "This first sentence")
    refute String.contains?(spoken, "breath")
  end

  test "a deferred turn speaks a local filler while waiting for the bridge" do
    {:ok, media} = FakeMedia.start_link([])

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: "agent-filler-#{System.unique_integer([:positive, :monotonic])}",
        media_session: media,
        ai: FakeAI,
        brain: SilentBrain,
        filler_delay_ms: 50,
        filler_texts: ["Let me check on that."]
      })

    send(agent, {:bridge, :attached})

    for _ <- 1..3, do: send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})

    await(fn -> Enum.any?(VoiceAgent.transcript(agent), &(&1.role == :agent)) end, 2_000)

    assert Enum.any?(
             VoiceAgent.transcript(agent),
             &(&1.role == :agent and &1.text == "Let me check on that.")
           )

    assert FakeMedia.sent(media) != []
  end

  test "a bridge reply cancels the pending filler" do
    {:ok, media} = FakeMedia.start_link([])

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: "agent-filler-cancel-#{System.unique_integer([:positive, :monotonic])}",
        media_session: media,
        ai: FakeAI,
        brain: SilentBrain,
        filler_delay_ms: 500,
        filler_texts: ["Let me check on that."]
      })

    send(agent, {:bridge, :attached})

    for _ <- 1..3, do: send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})

    # The caller turn is recorded (the brain deferred)...
    await(fn -> length(VoiceAgent.transcript(agent)) == 1 end)

    # ...and the bridge answers well before the 500 ms filler delay.
    send(agent, {:speak, "Here is the real answer."})
    await(fn -> VoiceAgent.mode(agent) == :speaking end)

    Process.sleep(700)

    texts = Enum.map(VoiceAgent.transcript(agent), & &1.text)
    assert "Here is the real answer." in texts
    refute "Let me check on that." in texts
  end

  test "no filler is spoken when the brain answers locally" do
    {agent, media} = start_agent()

    for _ <- 1..3, do: send(agent, {:audio, frame(1000)})
    for _ <- 1..8, do: send(agent, {:audio, frame(0)})

    await(fn -> VoiceAgent.mode(agent) == :idle and FakeMedia.sent(media) != [] end)
    Process.sleep(200)

    refute Enum.any?(
             VoiceAgent.transcript(agent),
             &(&1.role == :agent and &1.text == "Let me check on that.")
           )
  end
end
