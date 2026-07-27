defmodule VoiceCore.CallRegistry do
  @moduledoc """
  Registry for active call sessions using OTP Registry.
  """

  @spec child_spec(any) :: Supervisor.child_spec()
  def child_spec(_) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__
    )
  end

  def register(call_id, pid) do
    case Registry.register(__MODULE__, call_id, pid) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  def lookup(call_id) do
    case Registry.lookup(__MODULE__, call_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def unregister(call_id) do
    Registry.unregister(__MODULE__, call_id)
  end
end
