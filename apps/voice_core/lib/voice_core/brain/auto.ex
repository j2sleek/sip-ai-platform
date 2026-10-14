defmodule VoiceCore.Brain.Auto do
  @moduledoc """
  Direction-aware brain (`VOICE_BRAIN=auto`): picks the brain per call from who
  owns the call, keeping the brain/body split of ADR-0010 (Layer 3 of the
  latency/context plan).

    * **Bridged** — `control_api` knows the call (an OpenCode-`originated`
      conversation). Defer to `VoiceCore.Brain.External` (`{:ok, ""}`): the body
      only transcribes + reports, and OpenCode answers through the MCP `speak`
      path over `control_api`. The `VoiceAgent` masks OpenCode's (higher) latency
      with a short local filler (Layer 2).
    * **Unbridged** — an *inbound* call `control_api` does not know. Answer
      locally with the configured `:brain_local` (default
      `VoiceCore.Brain.HTTPLLM`), so dial-in calls stay conversational with no
      OpenCode attached and no dead air.

  The bridge status is resolved by `VoiceCore.ControlBus` (the process that
  already discovers whether `control_api` knows the call) and forwarded to the
  agent as `{:bridge, :attached | :absent}`; the agent passes it in
  `context[:bridge]`. While the status is still `:unknown` the local brain
  answers — the safe fallback, so a call is never silent.
  """

  @behaviour VoiceCore.Brain

  @impl true
  def respond(transcript, context, timeout_ms) do
    case Map.get(context, :bridge) do
      :attached -> VoiceCore.Brain.External.respond(transcript, context, timeout_ms)
      _ -> local_brain().respond(transcript, context, timeout_ms)
    end
  end

  defp local_brain do
    Application.get_env(:voice_core, :brain_local, VoiceCore.Brain.HTTPLLM)
  end
end
