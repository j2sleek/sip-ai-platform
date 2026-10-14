defmodule VoiceCore.Brain do
  @moduledoc """
  `VoiceCore.Brain` is the decision boundary of the voice agent: it turns a
  transcribed utterance into a textual reply. This is where the coding agent
  (OpenCode) plugs into a live call — the real-time body never decides *what to
  say*, it only decides *when to listen/speak*.

  Implementations (see ADR-0010):

    * `VoiceCore.Brain.Static` — canned/echo replies (tests, demo, safe default)
    * `VoiceCore.Brain.HTTPLLM` — calls the platform `llm` service behind a
      provider interface; drives turn-taking entirely inside the body.
    * `VoiceCore.Brain.External` — no local reply: the utterance is reported to
      `control_api` and the brain is OpenCode over the telephony MCP server,
      which replies by posting `agent.speak` (delivered by `ControlBus`).

  All implementations must respect a timeout and never raise across the
  boundary — failures become a structured `{:error, reason}`. Returning
  `{:ok, ""}` means "nothing to say locally" (see `External`).
  """

  @type transcript :: binary()
  @type context :: %{optional(:call_id) => binary()}

  @doc "Returns a reply text for a user utterance, within the given timeout."
  @callback respond(transcript(), context, timeout_ms :: pos_integer()) ::
              {:ok, binary()} | {:error, term()}
end
