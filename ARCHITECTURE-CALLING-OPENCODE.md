# Architecture: Calling OpenCode from the App

Current (brain/body split - ADR-0010): OpenCode → MCP → Control API → Telephony/Python Services
Alternative (platform-driven): Control API/Voice Core → spawns OpenCode CLI → gets response → speaks

To support "call or text opencode" programmatically:
1. Add bridge in voice_core (Elixir) to spawn opencode CLI with proper args
2. Or add endpoint in control_api to trigger opencode reasoning
3. Keep both patterns possible

Implementation example in Elixir (conceptual):
```elixir
defmodule VoiceCore.Brain.OpenCode do
  def generate(messages) do
    prompt = format_messages(messages)
    {out, 0} = System.cmd("opencode", ["run", "--format", "json", prompt], env: %{})
    Jason.decode!(out)
  end
end
```

But need to handle sessions, timeouts, streaming.
