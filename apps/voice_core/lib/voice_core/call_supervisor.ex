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
    spec = {VoiceCore.CallSession, Map.put(args, :call_id, call_id)}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_call(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
