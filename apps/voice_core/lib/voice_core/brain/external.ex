defmodule VoiceCore.Brain.External do
  @moduledoc """
  `VoiceCore.Brain` implementation for the **OpenCode-driven** ("MCP brain")
  mode: the real-time body never decides *what to say*.

  It transcribes the caller's utterance and reports it to `control_api`
  (`utterance.user`); the external brain — OpenCode over the telephony MCP
  server (`originate_call` / `wait_for_input` / `speak`) — replies by posting
  `agent.speak`, which `VoiceCore.ControlBus` forwards to the agent as a
  `{:speak, text}` message.

  `respond/3` therefore always returns an empty reply; the agent treats that as
  "nothing to say locally — wait for the bridge" (it does not synthesize or
  play anything). Select it with `VOICE_BRAIN=external` and
  `CONTROL_API_ENABLED=true` (see `docs/OPENCODE-INTEGRATION.md`).
  """

  @behaviour VoiceCore.Brain

  @impl true
  def respond(_transcript, _context, _timeout_ms), do: {:ok, ""}
end
