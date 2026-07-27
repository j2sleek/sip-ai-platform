defmodule VoiceCore.CallSession do
  @moduledoc """
  Manages an individual call session.
  """

  use GenServer
  require Logger

  # State: :new, :ringing, :answered, :active, :ending, :ended
  defstruct [:call_id, :caller_id, :destination, :source, :state, :media_session, :start_time]

  # --- Struct API (Pure Functions for Testing) ---

  def new(call_id, source, caller_id, destination) do
    %__MODULE__{
      call_id: call_id,
      source: source,
      caller_id: caller_id,
      destination: destination,
      state: :new,
      start_time: System.system_time(:millisecond)
    }
  end

  def connect(session), do: %{session | state: :connected}
  def media_active(session), do: %{session | state: :media_active}
  def end_session(session), do: %{session | state: :ending}
  def terminate(session), do: %{session | state: :ended}

  def active?(session), do: session.state in [:active, :connected, :media_active]
  def ended?(session), do: session.state == :ended

  # --- GenServer API ---

  def start_link(args) do
    call_id = Map.fetch!(args, :call_id)
    GenServer.start_link(__MODULE__, args, name: via_tuple(call_id))
  end

  @impl true
  def init(args) do
    call_id = Map.fetch!(args, :call_id)

    # Register in CallRegistry
    case Registry.register(VoiceCore.CallRegistry, call_id, self()) do
      {:ok, _} ->
        Logger.info("CallSession started for #{call_id}")
        {:ok, new(call_id, Map.get(args, :source), Map.get(args, :caller_id), Map.get(args, :destination))}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp via_tuple(call_id) do
    {:via, Registry, {VoiceCore.CallRegistry, call_id}}
  end
end
