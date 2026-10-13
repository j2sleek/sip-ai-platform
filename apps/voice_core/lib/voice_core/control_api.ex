defmodule VoiceCore.ControlApi do
  @moduledoc """
  Outbound bridge from the media body (`voice_core`) to `control_api`.

  `voice_core` is the *body* (media + STT/TTS + turn-taking); `control_api` is the
  shared bus with the brain (OpenCode over the telephony MCP server). This module
  is the single place the core talks to it:

    * `report/3` posts call/transcript progress (`utterance.user`,
      `utterance.agent`, `call.answered`, `call.ended`);
    * `events/4` long-polls brain→body instructions (`agent.speak`).

  The bridge is inert unless `CONTROL_API_ENABLED=true` (see `config/runtime.exs`).
  Every request is bounded by a timeout; failures are `{:error, reason}` and are
  never raised into latency-sensitive processes.
  """

  require Logger

  @doc "True when the control_api bridge is configured and switched on."
  @spec enabled?() :: boolean()
  def enabled? do
    cfg = config()
    cfg[:enabled] == true and is_binary(cfg[:base_url]) and cfg[:base_url] != ""
  end

  @doc """
  Best-effort event report to control_api. No-op (returns `:ok`) when the bridge
  is disabled or `call_id` is empty; never raises.
  """
  @spec report(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def report(call_id, type, data) when is_binary(call_id) and is_binary(type) do
    if call_id == "" or not enabled?() do
      :ok
    else
      case post_event(call_id, type, data, request_timeout()) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("control_api report #{type} failed: #{inspect(reason)}", call_id: call_id)
          {:error, reason}
      end
    end
  end

  @doc "POST one event (blocking, bounded by `timeout`)."
  @spec post_event(String.t(), String.t(), map(), pos_integer()) :: :ok | {:error, term()}
  def post_event(call_id, type, data, timeout) do
    url = base_url() <> "/api/v1/calls/" <> call_id <> "/events"
    body = Jason.encode!(%{"type" => type, "data" => data})

    case request(:post, url, body, timeout) do
      {:ok, status, _} when status in 200..299 -> :ok
      {:ok, status, _} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Long-poll events after `since`. Returns `{:ok, events, cursor}`,
  `{:error, :not_found}` when the call is unknown to control_api, or
  `{:error, reason}`.
  """
  @spec events(String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()], non_neg_integer()} | {:error, term()}
  def events(call_id, since, wait_ms, timeout) do
    query =
      URI.encode_query(%{
        "since" => Integer.to_string(since),
        "wait" => Integer.to_string(wait_ms)
      })

    url = base_url() <> "/api/v1/calls/" <> call_id <> "/events?" <> query

    case request(:get, url, nil, timeout) do
      {:ok, 200, body} -> decode_events(body)
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, status, _} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── internals ──────────────────────────────────────────────────────────────

  defp decode_events(body) do
    case Jason.decode(body) do
      {:ok, %{"events" => events, "cursor" => cursor}}
      when is_list(events) and is_integer(cursor) ->
        {:ok, events, cursor}

      {:ok, other} ->
        {:error, {:unexpected_body, other}}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp request(method, url, body, timeout) do
    headers = auth_headers()
    http_opts = [timeout: timeout, connect_timeout: min(timeout, 5_000)]
    opts = [body_format: :binary]

    request =
      case body do
        nil -> {String.to_charlist(url), headers}
        _ -> {String.to_charlist(url), headers, ~c"application/json", body}
      end

    :httpc.request(method, request, http_opts, opts) |> normalize()
  end

  defp normalize({:ok, {{_version, status, _reason}, _headers, body}}) when is_binary(body),
    do: {:ok, status, body}

  defp normalize({:ok, {{_version, status, _reason}, _headers}}), do: {:ok, status, ""}
  defp normalize({:error, reason}), do: {:error, reason}

  defp auth_headers do
    case config()[:token] do
      token when is_binary(token) and token != "" ->
        [{~c"authorization", String.to_charlist("Bearer " <> token)}]

      _ ->
        []
    end
  end

  defp config, do: Application.get_env(:voice_core, :control_api, []) |> Map.new()

  defp base_url, do: String.trim_trailing(config()[:base_url] || "http://127.0.0.1:4001", "/")
  defp request_timeout, do: config()[:request_timeout_ms] || 5_000
end
