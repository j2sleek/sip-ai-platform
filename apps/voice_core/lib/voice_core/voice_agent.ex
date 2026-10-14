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

  Barge-in: playback is owned by `VoiceCore.MediaSession` (which paces the
  queued PCM at real time); a `:speech_start` event flushes that queue so
  playback stops within one 20 ms frame, and the interruption is captured as the
  next utterance (Phase 7 essence).
  """

  use GenServer
  require Logger

  alias VoiceCore.VoiceAgent.Turn

  # Fallback filler phrases (Layer 2) when none are configured.
  @default_filler_texts ["Let me check on that.", "One moment.", "Let me take a look."]

  # Spoken once when a *deferred* (bridged) turn gets no answer within
  # `reply_timeout_ms` — e.g. OpenCode is rate-limited or otherwise unavailable.
  @default_reply_timeout_text "The project agent is unavailable until tomorrow."

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

    max_reply_chars =
      Map.get(args, :max_reply_chars, Map.get(agent_cfg, :max_reply_chars, 320))

    # Layer 2 latency filler: spoken only when the brain defers (empty reply) and
    # no bridge speech has arrived within `delay_ms` (see ADR-0017).
    filler = %{
      enabled: Map.get(args, :filler_enabled, Map.get(agent_cfg, :filler_enabled, true)),
      delay_ms: Map.get(args, :filler_delay_ms, Map.get(agent_cfg, :filler_delay_ms, 900)),
      texts:
        Map.get(
          args,
          :filler_texts,
          Map.get(agent_cfg, :filler_texts, @default_filler_texts)
        )
    }

    # Layer 2 safety net: if a deferred (bridged) turn still has no answer after
    # `reply_timeout_ms`, speak `reply_timeout_text` so the caller is never left
    # in silence (e.g. OpenCode is rate-limited or down).
    reply_timeout_ms =
      Map.get(args, :reply_timeout_ms, Map.get(agent_cfg, :reply_timeout_ms, 8_000))

    reply_timeout_text =
      Map.get(
        args,
        :reply_timeout_text,
        Map.get(agent_cfg, :reply_timeout_text, @default_reply_timeout_text)
      )

    state = %{
      call_id: call_id,
      media_session: Map.fetch!(args, :media_session),
      brain: Map.get(args, :brain, VoiceCore.Brain.Static),
      ai: Map.get(args, :ai, VoiceCore.AI),
      turn: Turn.new(Map.merge(agent_cfg, %{call_id: call_id})),
      mode: :idle,
      transcript: [],
      # Incremented whenever playback starts or is cancelled; in-flight TTS
      # results carrying a stale sequence are dropped (a barge-in during
      # synthesis must not resurrect the cancelled reply).
      speak_seq: 0,
      # Incremented for every caller utterance; STT/brain results carrying a
      # stale sequence are dropped, so a superseded turn can never speak over
      # (or behind) the turn that replaced it.
      turn_seq: 0,
      # Layer 3 bridge status resolved by `ControlBus`: `:attached` → control_api
      # owns the call (external brain answers); `:absent` → inbound, answer
      # locally; `:unknown` → not resolved yet (answer locally, safe fallback).
      bridge: :unknown,
      # Layer 2 latency-filler state.
      filler: filler,
      filler_index: 0,
      filler_timer: nil,
      # Layer 2 safety-net state (a deferred turn with no bridge answer).
      reply_timeout_ms: reply_timeout_ms,
      reply_timeout_text: reply_timeout_text,
      reply_timer: nil,
      # Hard cap on spoken reply length (characters). Bounds TTS synthesis +
      # playback time, which is the dominant per-turn latency for cloud TTS.
      max_reply_chars: max_reply_chars,
      playback_timer: nil,
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

  # `ControlBus` resolved whether control_api owns this call: `:attached` for an
  # OpenCode-originated call (the external brain answers), `:absent` for an
  # inbound call we answer locally. `VoiceCore.Brain.Auto` reads this per turn.
  def handle_info({:bridge, status}, state) when status in [:attached, :absent] do
    Logger.info("VoiceAgent #{state.call_id}: bridge #{status}", call_id: state.call_id)
    {:noreply, %{state | bridge: status}}
  end

  def handle_info({:filler, turn}, state) do
    if turn == state.turn_seq do
      {text, state} = next_filler(state)
      Logger.info("VoiceAgent #{state.call_id}: speaking filler", call_id: state.call_id)
      {:noreply, start_speaking(text, %{state | filler_timer: nil})}
    else
      {:noreply, %{state | filler_timer: nil}}
    end
  end

  # Safety net: the brain deferred (a bridged/OpenCode call) and the bridge still
  # has not spoken within `reply_timeout_ms` — speak the configured line so the
  # caller is never left in silence (e.g. OpenCode is rate-limited or down). Real
  # speech arriving first cancels this; a newer turn supersedes it.
  def handle_info({:reply_timeout, turn}, state) do
    cond do
      turn != state.turn_seq ->
        {:noreply, %{state | reply_timer: nil}}

      state.mode == :listening ->
        # The caller is mid-utterance; their fresh turn supersedes this one.
        {:noreply, %{state | reply_timer: nil}}

      true ->
        Logger.info(
          "VoiceAgent #{state.call_id}: bridge silent — speaking unavailable fallback",
          call_id: state.call_id
        )

        {:noreply, start_speaking(state.reply_timeout_text, %{state | reply_timer: nil})}
    end
  end

  # STT produced a transcript for the current utterance.
  def handle_info({:utterance, turn, text}, state) do
    if turn == state.turn_seq do
      entry = %{role: :user, text: text, at: System.system_time(:millisecond)}
      {:noreply, %{state | transcript: [entry | state.transcript]}}
    else
      # Stale STT result for a superseded turn — drop it.
      {:noreply, state}
    end
  end

  # Brain + STT finished.
  def handle_info({:agent_reply, turn, {:ok, text}}, state) do
    if turn == state.turn_seq do
      cancel_timer(state.processing_timer)

      Logger.info("VoiceAgent #{state.call_id}: reply generated (#{byte_size(text)} chars)",
        call_id: state.call_id
      )

      if String.trim(text) == "" do
        # Empty reply: an external/MCP brain defers to the bridge; nothing to say
        # locally. Only stand down if we are still the active (processing) turn —
        # a bridge `speak` may already have moved us to :speaking. Schedule a
        # filler so the caller hears *something* if OpenCode is slow to reply, and
        # a longer safety net for when OpenCode never replies at all.
        state = idle_if_processing(state)
        state = schedule_filler(turn, state)
        {:noreply, schedule_reply_timeout(turn, state)}
      else
        {:noreply, start_speaking(text, state)}
      end
    else
      # A newer utterance superseded this turn — never speak its stale reply.
      {:noreply, state}
    end
  end

  def handle_info({:agent_reply, turn, {:error, reason}}, state) do
    if turn == state.turn_seq do
      cancel_timer(state.processing_timer)

      Logger.error("VoiceAgent #{state.call_id}: brain error #{inspect(reason)}",
        call_id: state.call_id
      )

      {:noreply, idle_if_processing(state)}
    else
      {:noreply, state}
    end
  end

  # The brain bridge (control_api / OpenCode via MCP) asked us to speak text.
  # Same playback path as an LLM reply; barge-in still applies. The bridge is the
  # authority, so any local turn still in flight is invalidated.
  def handle_info({:speak, text}, state) when is_binary(text) do
    Logger.info("VoiceAgent #{state.call_id}: speak requested (#{byte_size(text)} chars)",
      call_id: state.call_id
    )

    {:noreply, start_speaking(text, invalidate_turn(state))}
  end

  def handle_info({:tts_ready, seq, pcm}, state) when is_binary(pcm) do
    if seq == state.speak_seq and byte_size(pcm) > 0 do
      # Hand the whole clip to the media session, which owns real-time pacing
      # (single clock). If the clip already finished, this is a no-op.
      case VoiceCore.MediaSession.send_audio(state.media_session, pcm) do
        :ok ->
          duration_ms = pcm_duration_ms(pcm, state.turn.sample_rate)
          timer = Process.send_after(self(), {:playback_done, seq}, duration_ms + 250)
          {:noreply, %{state | playback_timer: timer}}

        {:error, reason} ->
          Logger.warning("VoiceAgent #{state.call_id}: playback send failed #{inspect(reason)}")
          {:noreply, %{state | mode: :idle}}
      end
    else
      # Stale TTS result (barge-in while synthesizing) — drop it.
      {:noreply, state}
    end
  end

  def handle_info({:tts_ready, _seq, _empty}, state), do: {:noreply, %{state | mode: :idle}}

  def handle_info({:tts_failed, seq, reason}, state) do
    if seq == state.speak_seq do
      Logger.error("VoiceAgent #{state.call_id}: TTS failed #{inspect(reason)}",
        call_id: state.call_id
      )

      {:noreply, %{state | mode: :idle}}
    else
      {:noreply, state}
    end
  end

  # Estimated end of playback (media session keeps sending silence after). Only
  # flips to idle if we are still in this turn's speaking state.
  def handle_info({:playback_done, seq}, state) do
    if seq == state.speak_seq and state.mode == :speaking do
      {:noreply, %{state | mode: :idle, playback_timer: nil}}
    else
      {:noreply, %{state | playback_timer: nil}}
    end
  end

  # STT+brain exceeded their budget — never leave the call stuck.
  def handle_info(:processing_timeout, state) do
    Logger.error("VoiceAgent #{state.call_id}: processing timed out", call_id: state.call_id)
    {:noreply, idle_if_processing(%{state | processing_timer: nil})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.processing_timer)
    cancel_timer(state.playback_timer)
    cancel_timer(state.filler_timer)
    cancel_timer(state.reply_timer)
    Logger.info("VoiceAgent #{state.call_id}: terminating")
    :ok
  end

  # ─── Turn event handling ────────────────────────────────────────────────────

  defp handle_turn_event(:none, _pcm, state), do: {:noreply, state}

  defp handle_turn_event(:speech_start, _pcm, state) do
    # The caller started talking: a pending filler / safety-net timer is no
    # longer needed (their fresh turn will supersede this one).
    state = cancel_filler(state)
    state = cancel_reply_timeout(state)

    case state.mode do
      :speaking ->
        # Barge-in: stop playback now and invalidate the in-flight reply so a
        # late TTS clip cannot resurrect the cancelled turn.
        state = state |> cancel_speech() |> invalidate_turn()
        :telemetry.execute([:voice_core, :voice_agent, :barge_in], %{}, %{call_id: state.call_id})
        Logger.info("VoiceAgent #{state.call_id}: barge-in detected", call_id: state.call_id)
        {:noreply, %{state | mode: :listening}}

      :processing ->
        # The caller started talking while we were thinking: abandon the pending
        # reply so it can never speak over them.
        {:noreply, %{invalidate_turn(state) | mode: :listening}}

      _ ->
        :telemetry.execute([:voice_core, :voice_agent, :speech_start], %{}, %{
          call_id: state.call_id
        })

        {:noreply, %{state | mode: :listening}}
    end
  end

  defp handle_turn_event({:speech_end, pcm}, _frame_pcm, state) do
    # Always process the freshest utterance. If a previous turn is still in
    # flight, it is superseded: `kick_processing/2` bumps `turn_seq`, so the old
    # turn's late STT/brain result is dropped instead of being spoken late or
    # out of order.
    Logger.info("VoiceAgent #{state.call_id}: utterance endpointed (#{byte_size(pcm)} bytes)",
      call_id: state.call_id
    )

    state = kick_processing(pcm, state)
    {:noreply, %{state | mode: :processing}}
  end

  defp kick_processing(pcm, state) do
    # A previous turn's watchdog may still be pending; replace it so a stale
    # `:processing_timeout` can't flip a later (or speaking) turn to idle.
    cancel_timer(state.processing_timer)
    # A new turn supersedes any filler / safety-net timer queued for the
    # previous (deferred) turn.
    cancel_timer(state.filler_timer)
    cancel_timer(state.reply_timer)

    turn = state.turn_seq + 1
    agent = self()
    stt_timeout = state.stt_timeout_ms
    llm_timeout = state.llm_timeout_ms
    brain = state.brain
    ai = state.ai
    call_id = state.call_id
    # Snapshot the bridge status for the brain (Layer 3 routing, ADR-0017).
    bridge = state.bridge

    spawn(fn ->
      result =
        case ai.transcribe(pcm, stt_timeout) do
          {:ok, text} ->
            Logger.info("VoiceAgent #{call_id}: utterance=#{inspect(String.slice(text, 0, 160))}",
              call_id: call_id
            )

            send(agent, {:utterance, turn, text})
            VoiceCore.ControlApi.report(call_id, "utterance.user", %{"text" => text})
            brain.respond(text, %{call_id: call_id, bridge: bridge}, llm_timeout)

          {:error, reason} ->
            {:error, {:stt_failed, reason}}
        end

      send(agent, {:agent_reply, turn, result})
    end)

    timeout = state.stt_timeout_ms + state.llm_timeout_ms + 5_000
    timer = Process.send_after(self(), :processing_timeout, timeout)

    %{
      state
      | processing_timer: timer,
        turn_seq: state.turn_seq + 1,
        filler_timer: nil,
        reply_timer: nil
    }
  end

  # Records an agent utterance, reports it to control_api, and synthesizes +
  # plays it. Shared by LLM replies and bridge-injected `{:speak, ...}`.
  defp start_speaking(text, state) do
    text = clamp_reply(text, state)
    entry = %{role: :agent, text: text, at: System.system_time(:millisecond)}

    if text != "" do
      VoiceCore.ControlApi.report(state.call_id, "utterance.agent", %{text: text})
    end

    # A new utterance supersedes any audio still draining (e.g. an injected
    # `speak` over a reply). Bump the sequence so a late TTS result is dropped.
    VoiceCore.MediaSession.flush(state.media_session)
    seq = state.speak_seq + 1

    # Cancel any pending playback watchdog, but do NOT store the return value of
    # `cancel_timer/1` (it used to be a remaining-ms integer or the atom `:ok`).
    # That corrupted the timer field and made the next barge-in/terminate raise
    # `ArgumentError: not a reference`, taking the whole call down.
    cancel_timer(state.playback_timer)

    # Real speech supersedes any filler queued for a deferred turn.
    cancel_timer(state.filler_timer)

    state = %{
      state
      | transcript: [entry | state.transcript],
        mode: :speaking,
        speak_seq: seq,
        playback_timer: nil,
        filler_timer: nil
    }

    agent = self()

    spawn(fn ->
      case state.ai.synthesize(text, state.tts_timeout_ms) do
        {:ok, pcm} -> send(agent, {:tts_ready, seq, pcm})
        {:error, reason} -> send(agent, {:tts_failed, seq, reason})
      end
    end)

    state
  end

  # Stops playback now and invalidates any in-flight synthesis for this reply.
  defp cancel_speech(state) do
    cancel_timer(state.playback_timer)
    VoiceCore.MediaSession.flush(state.media_session)
    %{state | speak_seq: state.speak_seq + 1, playback_timer: nil}
  end

  # Invalidate any in-flight turn so its late STT/brain result is discarded.
  defp invalidate_turn(state) do
    cancel_timer(state.processing_timer)
    cancel_timer(state.filler_timer)
    cancel_timer(state.reply_timer)

    %{
      state
      | turn_seq: state.turn_seq + 1,
        processing_timer: nil,
        filler_timer: nil,
        reply_timer: nil
    }
  end

  # Cancel a pending filler (a superseded/deferred turn no longer needs it).
  defp cancel_filler(state) do
    cancel_timer(state.filler_timer)
    %{state | filler_timer: nil}
  end

  # Cancel a pending safety-net timer (real speech arrived, or the caller spoke).
  defp cancel_reply_timeout(state) do
    cancel_timer(state.reply_timer)
    %{state | reply_timer: nil}
  end

  # Queue a filler for a deferred turn — unless filler is disabled/empty or the
  # call is known to have no bridge (`:absent`, an inbound call in `external`
  # mode), where a filler would only be followed by silence.
  defp schedule_filler(_turn, %{bridge: :absent} = state), do: state

  defp schedule_filler(turn, %{filler: %{enabled: true, delay_ms: delay, texts: [_ | _]}} = state)
       when is_integer(delay) and delay > 0 do
    timer = Process.send_after(self(), {:filler, turn}, delay)
    %{state | filler_timer: timer}
  end

  defp schedule_filler(_turn, state), do: state

  # Queue the safety net for a deferred turn — unless there is no bridge
  # (`:absent`), the text is empty, or the budget is disabled. Like the filler,
  # it is cancelled the moment real speech arrives or a newer turn supersedes it.
  defp schedule_reply_timeout(_turn, %{bridge: :absent} = state), do: state

  defp schedule_reply_timeout(turn, %{reply_timeout_ms: ms, reply_timeout_text: text} = state)
       when is_integer(ms) and ms > 0 and is_binary(text) and text != "" do
    timer = Process.send_after(self(), {:reply_timeout, turn}, ms)
    %{state | reply_timer: timer}
  end

  defp schedule_reply_timeout(_turn, state), do: state

  defp next_filler(%{filler: %{texts: []}} = state), do: {"", state}

  defp next_filler(%{filler: %{texts: texts}} = state) do
    text = Enum.at(texts, rem(state.filler_index, length(texts)))
    {text, %{state | filler_index: state.filler_index + 1}}
  end

  defp idle_if_processing(%{mode: :processing} = state), do: %{state | mode: :idle}
  defp idle_if_processing(state), do: state

  # Bound the spoken reply so a chatty model can't stretch TTS + playback
  # unboundedly (cloud TTS latency and playback time both scale with length).
  defp clamp_reply(text, %{max_reply_chars: max} = state)
       when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) <= max do
      text
    else
      clipped = text |> String.slice(0, max) |> trim_to_boundary()

      Logger.info(
        "VoiceAgent #{state.call_id}: reply clamped (#{String.length(text)}→#{String.length(clipped)} chars)",
        call_id: state.call_id
      )

      clipped
    end
  end

  defp clamp_reply(text, _state), do: text

  # Prefer cutting on a sentence end; otherwise on a word boundary.
  defp trim_to_boundary(text) do
    case Regex.run(~r/^(.*[.!?])(?:\s|$)/s, text) do
      [_, sentence] ->
        sentence

      _ ->
        case Regex.run(~r/^(.*\S)\s+\S*$/s, text) do
          [_, words] -> words
          _ -> String.trim_trailing(text)
        end
    end
  end

  # Safe timer cancellation: accepts `nil` or a timer reference and never raises.
  # `Process.cancel_timer/1` raises `ArgumentError` for anything else, which used
  # to crash the agent (and with it the call) on barge-in/terminate.
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_timer(_other), do: :ok

  defp pcm_duration_ms(pcm, sample_rate) when sample_rate > 0 do
    round(div(byte_size(pcm), 2) * 1000 / sample_rate)
  end

  defp pcm_duration_ms(_pcm, _sample_rate), do: 0
end
