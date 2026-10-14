defmodule VoiceCore.ControlBus do
  @moduledoc """
  Per-call bridge that turns brain→body instructions from control_api into
  `{:speak, text}` messages for the call's `VoiceCore.VoiceAgent`.

  The brain (OpenCode via the telephony MCP server) writes `agent.speak` events
  through `POST /api/v1/calls/:id/speak`; this process long-polls the call's event
  stream and forwards each instruction to the agent, which owns TTS. It also
  delivers the greeting (the first `agent.speak` queued at originate).

  It is also the oracle for *whether* control_api owns the call: on the first
  successful poll it tells the agent `{:bridge, :attached}`; when control_api
  reports the call unknown (`:not_found`, i.e. an inbound call) it tells the
  agent `{:bridge, :absent}` before stopping. `VoiceCore.Brain.Auto` uses that to
  pick the external vs local brain per call (Layer 3, ADR-0017).

  Long-polling (rather than pushing) keeps voice_core free of an inbound HTTP
  surface: it only makes outbound, timeout-bounded requests. When the call is not
  known to control_api (inbound calls), the bus speaks the configured local
  greeting once and stops.
  """

  use GenServer
  require Logger

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) when is_map(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    state = %{
      call_id: Map.fetch!(args, :call_id),
      agent: Map.fetch!(args, :agent),
      greeting: Map.get(args, :greeting, ""),
      cursor: Map.get(args, :cursor, 0),
      greeted: false,
      notified: false,
      poll_wait_ms: Map.get(args, :poll_wait_ms, 1_000),
      request_timeout_ms: Map.get(args, :request_timeout_ms, 3_000)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case VoiceCore.ControlApi.events(
           state.call_id,
           state.cursor,
           state.poll_wait_ms,
           state.request_timeout_ms
         ) do
      {:ok, events, cursor} ->
        state = notify_bridge(state, :attached)
        state = Enum.reduce(events, %{state | cursor: cursor}, &handle_event/2)
        send(self(), :poll)
        {:noreply, state}

      {:error, :not_found} ->
        # Not a control_api-originated call (e.g. an inbound call) — tell the
        # agent there is no bridge, greet from local config, and stop polling.
        send(state.agent, {:bridge, :absent})
        state = maybe_greet(state)
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.debug("ControlBus #{state.call_id}: poll failed: #{inspect(reason)}",
          call_id: state.call_id
        )

        Process.send_after(self(), :poll, 1_000)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Tell the agent control_api owns this call — once (used by `Brain.Auto`).
  defp notify_bridge(%{notified: true} = state, _status), do: state

  defp notify_bridge(state, status) do
    send(state.agent, {:bridge, status})
    %{state | notified: true}
  end

  defp handle_event(%{"type" => "agent.speak", "data" => data}, state) when is_map(data) do
    case data["text"] do
      text when is_binary(text) and text != "" ->
        send(state.agent, {:speak, text})
        %{state | greeted: true}

      _ ->
        state
    end
  end

  defp handle_event(_event, state), do: state

  defp maybe_greet(%{greeted: true} = state), do: state

  defp maybe_greet(state) do
    if state.greeting != "" do
      send(state.agent, {:speak, state.greeting})
    end

    %{state | greeted: true}
  end
end
