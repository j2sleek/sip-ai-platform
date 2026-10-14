defmodule VoiceCore.FallbackIntegrationTest do
  @moduledoc """
  End-to-end check for the ADR-0019 no-reply safety net over the *real* media
  path: a real TCP AudioSocket client → `VoiceCore.AudioSocket.Server` →
  `VoiceCore.MediaSession` → `VoiceCore.VoiceAgent`.

  Unlike `VoiceCore.VoiceAgentTest` (which sends `{:audio, …}` straight to the
  agent), this drives the wire format, so it also proves the fallback audio is
  actually sent back out over the transport.
  """

  use ExUnit.Case, async: false

  alias VoiceCore.AudioSocket.Server, as: AudioServer
  alias VoiceCore.MediaSession
  alias VoiceCore.MediaTransport.AudioSocket
  alias VoiceCore.VoiceAgent

  @fallback "The project agent is unavailable until tomorrow."

  defmodule DeferBrain do
    @moduledoc false
    # An external/OpenCode brain: no local reply, the bridge is expected to speak.
    @behaviour VoiceCore.Brain
    @impl true
    def respond(_transcript, _context, _timeout), do: {:ok, ""}
  end

  defmodule FakeAI do
    @moduledoc false
    def transcribe(_pcm, _timeout), do: {:ok, "any update on the project?"}

    def synthesize(_text, timeout) when is_integer(timeout),
      do: {:ok, :binary.copy(<<0, 120>>, 800)}
  end

  test "a deferred turn with no bridge reply speaks the unavailable fallback" do
    call_id = VoiceCore.ARI.call_id("integration-#{System.unique_integer([:positive])}")

    # Forwards inbound media from the MediaSession to the agent (in production a
    # CallSession does this).
    forwarder =
      spawn(fn ->
        receive do
          {:forward_to, agent} -> forward_loop(agent)
        end
      end)

    {:ok, media} = MediaSession.start_link(%{call_id: call_id, listener: forwarder})

    {:ok, agent} =
      VoiceAgent.start_link(%{
        call_id: call_id,
        media_session: media,
        brain: DeferBrain,
        ai: FakeAI,
        # Isolate the safety net from the filler and keep the test fast.
        filler_enabled: false,
        reply_timeout_ms: 300,
        reply_timeout_text: @fallback
      })

    send(forwarder, {:forward_to, agent})
    send(agent, {:bridge, :attached})

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", AudioServer.port(), [:binary, active: false, packet: :raw])

    {:ok, handshake} = AudioSocket.create_uuid_frame(call_id)
    :ok = :gen_tcp.send(socket, handshake)

    # 3 × 100 ms of loud (speech) audio, then 800 ms of silence to endpoint.
    # The core keeps PCM big-endian internally; the AudioSocket wire is
    # little-endian, so encode the payloads as signed-little.
    speech = :binary.copy(<<1000::signed-little-16>>, 800)
    silence = :binary.copy(<<0::signed-little-16>>, 800)

    for _ <- 1..3 do
      {:ok, f} = AudioSocket.create_audio_frame(speech)
      :ok = :gen_tcp.send(socket, f)
    end

    for _ <- 1..8 do
      {:ok, f} = AudioSocket.create_audio_frame(silence)
      :ok = :gen_tcp.send(socket, f)
    end

    # The agent defers, then (no bridge `speak` arrives) speaks the fallback.
    await(fn ->
      Enum.any?(
        VoiceAgent.transcript(agent),
        &(&1.role == :agent and &1.text == @fallback)
      )
    end)

    # ...and the fallback audio actually left the core over the transport. The
    # pacer emits silence keepalives, so wait for an audio frame that is not all
    # zero (the FakeAI TTS payload is <<0,120>>, i.e. non-zero on the wire).
    assert await_non_silent_audio(socket, 2_000)

    :gen_tcp.close(socket)
  end

  # Reads AudioSocket frames until a non-silent 0x10 audio payload arrives.
  defp await_non_silent_audio(socket, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_non_silent_audio(socket, <<>>, deadline)
  end

  defp do_await_non_silent_audio(socket, buffer, deadline) do
    case AudioSocket.parse(buffer) do
      {:ok, %{type: :audio, payload: payload}, remaining} ->
        if payload != :binary.copy(<<0>>, byte_size(payload)) do
          true
        else
          do_await_non_silent_audio(socket, remaining, deadline)
        end

      {:ok, _other, remaining} ->
        do_await_non_silent_audio(socket, remaining, deadline)

      {:error, :incomplete, _partial} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          false
        else
          case :gen_tcp.recv(socket, 0, remaining) do
            {:ok, data} -> do_await_non_silent_audio(socket, buffer <> data, deadline)
            {:error, _} -> false
          end
        end

      {:error, _reason, _remaining} ->
        false
    end
  end

  defp forward_loop(agent) do
    receive do
      {:audio, pcm} -> send(agent, {:audio, pcm})
      _other -> :ok
    end

    forward_loop(agent)
  end

  defp await(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met before timeout")

      true ->
        Process.sleep(20)
        do_await(fun, deadline)
    end
  end
end
