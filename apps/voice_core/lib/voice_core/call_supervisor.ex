defmodule VoiceCore.CallSupervisor do
  @moduledoc """
  DynamicSupervisor for managing individual CallSession processes.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_call(call_id, args) do
    # `:transient` — restart only on abnormal exit. A CallSession that ends
    # normally (hangup / transport closed) must NOT be restarted, or every call
    # would respawn itself forever.
    spec = %{
      id: VoiceCore.CallSession,
      start: {VoiceCore.CallSession, :start_link, [Map.put(args, :call_id, call_id)]},
      restart: :transient
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_call(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
