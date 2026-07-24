defmodule VoiceCore do
  @moduledoc """
  Public entry point for the SIP AI Platform real-time core (`voice_core`).

  Phase 1 scope: this module exposes a health check and a structured health
  report that conforms to the shared `HealthResponse` contract
  (`packages/contracts`). Telephony (ARI), media transport, and AI orchestration
  are added in later phases — see `PLAN.md`.
  """

  @service_name "voice_core"

  @doc """
  Minimal health check.

  Returns `:ok` when the `:voice_core` supervision tree is alive, otherwise
  `{:error, reason}`.
  """
  @spec health() :: :ok | {:error, term()}
  def health do
    case Process.whereis(VoiceCore.Supervisor) do
      pid when is_pid(pid) -> :ok
      nil -> {:error, :supervisor_not_running}
    end
  end

  @doc """
  Structured health report matching the shared `HealthResponse` contract:
  `%{status, service, version}`.
  """
  @spec health_report() :: %{status: String.t(), service: String.t(), version: String.t()}
  def health_report do
    status = if health() == :ok, do: "ok", else: "error"
    %{status: status, service: @service_name, version: version()}
  end

  @doc "Returns the application version and current APP_ENV."
  @spec version() :: String.t()
  def version do
    case :application.get_key(:voice_core, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  @doc "Returns the configured application environment (from APP_ENV)."
  @spec app_env() :: String.t()
  def app_env, do: Application.get_env(:voice_core, :app_env, "development")
end
