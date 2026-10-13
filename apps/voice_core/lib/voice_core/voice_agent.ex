defmodule VoiceCore.VoiceAgent do
  @moduledoc """
  `VoiceCore.VoiceAgent` is the real-time *body* of a call's voice agent
  (ADR-0010): it owns turn-taking, endpointing, STT/TTS orchestration, and
  barge-in — while the *brain* (what to say) is delegated to a
  `VoiceCore.Brain` implementation that the MCP telephony server / OpenCode can
  attach to.

  Concurrency + isolation: one process per call, supervised by
  `VoiceCore.CallSupervisor`. Heavy network steps (STT/brain/TTS) run in Tasks
  (never blocking the agent's audio path — AGENTS.md rule 14), and every
  external call has a timeout (rule 7).

  Barge-in: while TTS playback is paced at 100 ms/chunk, a `:speech_start`
  event cancels the queue and the interruption is captured as the next
  utterance (Phase 7 essence).
  """

  use GenServer
  require Logger

  alias VoiceCore.VoiceAgent.Turn

  @speech_frame_ms 100

  # ─── API ────────────────────────────────────────────────────────────────────

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) do
    call_id = Map.fetch!(args, :call_id)
    GenServer.start_link(__MODULE__, args, name: via_tuple(call_id))
  end

  @doc "Current agent mode: one of :idle | :listening | :processing | :speaking."
  @spec mode(GenServer.server()) :: atom()
  def mode(pid_or_name), do: GenServer.call(pid_or_name, :mode, 5_000)

  @doc "Transcript + turn history for this call."
  @spec transcript(GenServer.server()) :: [String.t()]
  def transcript(pid_or_name), do: GenServer.call(pid_or_name, :transcript, 5_000)

  defp via_tuple(call_id) do
    {:via, Registry, {VoiceCore.CallRegistry, {:agent, call_id}}}
  end

  # ─── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    call_id = Map.fetch!(args, :call_id)
    ai = Application.get_env(:voice_core, :ai, []) |> Map.new()
    agent_cfg = Application.get_env(:voice_core, :agent, []) |> Map.new()

    state = %{
      call_id: call_id,
      media_session: Map.fetch!(args, :media_session),
      brain: Map.get(args, :brain, VoiceCore.Brain.Static),
      ai: Map.get(args, :ai, VoiceCore.AI),
      turn: Turn.new(Map.merge(agent_cfg, %{call_id: call_id})),
      mode: :idle,
      transcript: [],
      tts_queue: [],
      tts_timer: nil,
      processing_timer: nil,
      stt_timeout_ms: Map.get(ai, :stt_timeout_ms, 15_000),
      llm_timeout_ms: Map.get(ai, :llm_timeout_ms, 30_000),
      tts_timeout_ms: Map.get(ai, :tts_timeout_ms, 15_000)
    }

    Logger.info("VoiceAgent started for call #{call_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}
  def handle_call(:transcript, _from, state), do: {:reply, Enum.reverse(state.transcript), state}

  @impl true
  # Inbound audio from the media session — the real-time path.
  def handle_info({:audio, pcm}, state) do
    {turn, event} = Turn.feed_frame(state.turn, pcm)
    handle_turn_event(event, pcm, %{state | turn: turn})
  end

  def handle_info({:dtmf, digit}, state) do
    Logger.info("VoiceAgent #{state.call_id}: DTMF #{inspect(digit)}", call_id: state.call_id)
    {:noreply, state}
  end

  # STT produced a transcript for the current utterance.
  def handle_info({:utterance, text}, state) do
    entry = %{role: :user, text: text, at: System.system_time(:millisecond)}
    {:noreply, %{state | transcript: [entry | state.transcript]}}
  end

  # Brain + STT finished.
  def handle_info({:agent_reply, {:ok, text}}, state) do
    cancel_timer(state.processing_timer)

    Logger.info("VoiceAgent #{state.call_id}: reply generated (#{byte_size(text)} chars)",
      call_id: state.call_id
    )

    {:noreply, start_speaking(text, state)}
  end

  def handle_info({:agent_reply, {:error, reason}}, state) do
    cancel_timer(state.processing_timer)

    Logger.error("VoiceAgent #{state.call_id}: brain error #{inspect(reason)}",
      call_id: state.call_id
    )

    {:noreply, %{state | mode: :idle}}
  end

  # The brain bridge (control_api / OpenCode via MCP) asked us to speak text.
  # Same playback path as an LLM reply; barge-in still applies.
  def handle_info({:speak, text}, state) when is_binary(text) do
    Logger.info("VoiceAgent #{state.call_id}: speak requested (#{byte_size(text)} chars)",
      call_id: state.call_id
    )

    {:noreply, start_speaking(text, state)}
  end

  def handle_info({:tts_ready, pcm}, state) when byte_size(pcm) > 0 do
    chunks = chunk_pcm(pcm, 800 * 2)

    send(self(), :tts_tick)
    {:noreply, %{state | tts_queue: chunks, tts_timer: nil}}
  end

  def handle_info({:tts_ready, _empty}, state) do
    {:noreply, %{state | mode: :idle}}
  end

  def handle_info({:tts_failed, reason}, state) do
    Logger.error("VoiceAgent #{state.call_id}: TTS failed #{inspect(reason)}",
      call_id: state.call_id
    )

    {:noreply, %{state | mode: :idle}}
  end

  # Paced playback: one 100 ms PCM chunk per tick.
  def handle_info(:tts_tick, %{tts_queue: [chunk | rest]} = state) do
    case VoiceCore.MediaSession.send_audio(state.media_session, chunk) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("VoiceAgent #{state.call_id}: playback send failed #{inspect(reason)}")
    end

    case rest do
      [] ->
        {:noreply, %{state | tts_queue: [], mode: :idle, tts_timer: nil}}

      _ ->
        timer = Process.send_after(self(), :tts_tick, @speech_frame_ms)
        {:noreply, %{state | tts_queue: rest, tts_timer: timer}}
    end
  end

  def handle_info(:tts_tick, state), do: {:noreply, %{state | tts_queue: [], mode: :idle}}

  # STT+brain exceeded their budget — never leave the call stuck.
  def handle_info(:processing_timeout, state) do
    Logger.error("VoiceAgent #{state.call_id}: processing timed out", call_id: state.call_id)
    {:noreply, %{state | mode: :idle, processing_timer: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.processing_timer)
    cancel_timer(state.tts_timer)
    Logger.info("VoiceAgent #{state.call_id}: terminating")
    :ok
  end

  # ─── Turn event handling ────────────────────────────────────────────────────

  defp handle_turn_event(:none, _pcm, state), do: {:noreply, state}

  defp handle_turn_event(:speech_start, _pcm, state) do
    case state.mode do
      :speaking ->
        # Barge-in: cut TTS now; the interruption is already captured in the
        # turn buffer (the Turn core moved to :listening).
        cancel_tts(state)
        :telemetry.execute([:voice_core, :voice_agent, :barge_in], %{}, %{call_id: state.call_id})
        Logger.info("VoiceAgent #{state.call_id}: barge-in detected", call_id: state.call_id)
        {:noreply, %{state | mode: :listening}}

      _ ->
        :telemetry.execute([:voice_core, :voice_agent, :speech_start], %{}, %{
          call_id: state.call_id
        })

        {:noreply, %{state | mode: :listening}}
    end
  end

  defp handle_turn_event({:speech_end, pcm}, _frame_pcm, state) do
    if state.mode == :processing do
      # Already thinking about a previous utterance — drop this one (no queue
      # merging; keeps strict per-turn isolation).
      {:noreply, state}
    else
      Logger.info("VoiceAgent #{state.call_id}: utterance endpointed (#{byte_size(pcm)} bytes)",
        call_id: state.call_id
      )

      state = kick_processing(pcm, state)
      {:noreply, %{state | mode: :processing}}
    end
  end

  defp kick_processing(pcm, state) do
    # A previous turn's watchdog may still be pending; replace it so a stale
    # `:processing_timeout` can't flip a later (or speaking) turn to idle.
    cancel_timer(state.processing_timer)

    agent = self()
    stt_timeout = state.stt_timeout_ms
    llm_timeout = state.llm_timeout_ms
    brain = state.brain
    ai = state.ai
    call_id = state.call_id

    spawn(fn ->
      result =
        case ai.transcribe(pcm, stt_timeout) do
          {:ok, text} ->
            Logger.info("VoiceAgent #{call_id}: utterance=#{inspect(String.slice(text, 0, 160))}",
              call_id: call_id
            )

            send(agent, {:utterance, text})
            VoiceCore.ControlApi.report(call_id, "utterance.user", %{"text" => text})
            brain.respond(text, %{call_id: call_id}, llm_timeout)

          {:error, reason} ->
            {:error, {:stt_failed, reason}}
        end

      send(agent, {:agent_reply, result})
    end)

    timeout = state.stt_timeout_ms + state.llm_timeout_ms + 5_000
    timer = Process.send_after(self(), :processing_timeout, timeout)
    %{state | processing_timer: timer}
  end

  # Records an agent utterance, reports it to control_api, and synthesizes +
  # plays it. Shared by LLM replies and bridge-injected `{:speak, ...}`.
  defp start_speaking(text, state) do
    entry = %{role: :agent, text: text, at: System.system_time(:millisecond)}

    if text != "" do
      VoiceCore.ControlApi.report(state.call_id, "utterance.agent", %{text: text})
    end

    state = %{state | transcript: [entry | state.transcript], mode: :speaking}
    agent = self()

    spawn(fn ->
      case state.ai.synthesize(text, state.tts_timeout_ms) do
        {:ok, pcm} -> send(agent, {:tts_ready, pcm})
        {:error, reason} -> send(agent, {:tts_failed, reason})
      end
    end)

    state
  end

  defp cancel_tts(state) do
    cancel_timer(state.tts_timer)
    %{state | tts_queue: [], tts_timer: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp chunk_pcm(pcm, size) do
    do_chunk(pcm, size, [])
  end

  defp do_chunk(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_chunk(pcm, size, acc) when byte_size(pcm) <= size do
    Enum.reverse([pcm | acc])
  end

  defp do_chunk(pcm, size, acc) do
    <<chunk::binary-size(size), rest::binary>> = pcm
    do_chunk(rest, size, [chunk | acc])
  end
end
