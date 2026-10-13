defmodule VoiceCore.Brain do
  @moduledoc """
  `VoiceCore.Brain` is the decision boundary of the voice agent: it turns a
  transcribed utterance into a textual reply. This is where the coding agent
  (OpenCode) plugs into a live call — the real-time body never decides *what to
  say*, it only decides *when to listen/speak*.

  Implementations (see ADR-0010):

    * `VoiceCore.Brain.Static` — canned/echo replies (tests, demo, safe default)
    * `VoiceCore.Brain.HTTPLLM` — calls the platform `llm` service (Ollama
      behind a provider interface); the future `MCPBrain` will forward the
      utterance to a coding agent over the telephony MCP server.

  All implementations must respect a timeout and never raise across the
  boundary — failures become a structured `{:error, reason}`.
  """

  @type transcript :: binary()
  @type context :: %{optional(:call_id) => binary()}

  @doc "Returns a reply text for a user utterance, within the given timeout."
  @callback respond(transcript(), context, timeout_ms :: pos_integer()) ::
              {:ok, binary()} | {:error, term()}
end
