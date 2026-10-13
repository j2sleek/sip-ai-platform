defmodule VoiceCore.Brain.Static do
  @moduledoc """
  Deterministic `VoiceCore.Brain` for tests and demos — never requires a model
  or network. Replies echo the transcript prefixed by the configured persona,
  defaulting to a short canned acknowledgment.
  """

  @behaviour VoiceCore.Brain

  def respond(transcript, _context, _timeout_ms) do
    {:ok, reply_for(transcript)}
  end

  defp reply_for(""), do: "I'm listening. Please go ahead."
  defp reply_for(t), do: "Understood. You said: #{String.slice(t, 0, 200)}"
end
