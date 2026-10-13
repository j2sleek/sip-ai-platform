defmodule VoiceCore.MediaTransport do
  @moduledoc """
  `MediaTransport` is the abstraction separating telephony media from the rest
  of the core (AGENTS.md rule 4). Adapters (AudioSocket today; WebSocket/RTP in
  later phases) implement a small, symmetric interface: the core opens one
  bidirectional stream per call, pushes inbound frames to the owning session,
  and writes outbound PCM via `send_audio/2`.

  Call binding uses a transport-level connection id (`conn_id`). The UUID flow
  (Asterisk `res_audiosocket`) and the explicit `attach/2` flow both end in the
  `MediaSession` being registered under `{:media, key}` in `VoiceCore.CallRegistry`;
  see `VoiceCore.AudioSocket.Server`.
  """

  @type conn_id :: String.t()
  @type pcm :: binary()

  @doc "Human-readable transport name (e.g. `:audiosocket`)."
  @callback transport_name() :: atom()

  @doc "Bind a live transport connection to a call's media process."
  @callback attach(conn_id(), pid()) :: :ok | {:error, term()}

  @doc "Release a connection."
  @callback detach(conn_id()) :: :ok | {:error, term()}

  @doc "Send outbound PCM frames to the far end."
  @callback send_audio(conn_id(), pcm()) :: :ok | {:error, term()}

  @doc "Current transport statistics."
  @callback stats() :: map()
end
