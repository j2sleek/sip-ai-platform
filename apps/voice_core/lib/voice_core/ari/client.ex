defmodule VoiceCore.ARI.Client do
  @moduledoc """
  Minimal Asterisk ARI REST client for the control operations `voice_core` needs
  while a channel is inside the Stasis application:

    * `answer/2`        — bring the channel up,
    * `set_variable/4`  — publish the call id to the dialplan (`AI_UUID`),
    * `continue/5`      — leave Stasis and hand the channel to the `[ai]`
      dialplan context that runs `AudioSocket(${AI_UUID}, ...)`,
    * `hangup/2`        — end the channel.

  This is *control* only: no media, no AI, no SIP signalling (AGENTS.md rules
  1–3). Uses OTP `:httpc` (no extra deps) with explicit timeouts; every failure is
  a structured `{:error, reason}` and never raises across the boundary.
  """

  require Logger

  @type channel_id :: String.t()

  @doc "Answer the channel (idempotent on an already-answered channel)."
  @spec answer(channel_id(), pos_integer()) :: :ok | {:error, term()}
  def answer(channel_id, timeout \\ 5_000) do
    post("channels/" <> channel_id <> "/answer", ~c"", timeout)
  end

  @doc "Set a channel variable visible to the dialplan."
  @spec set_variable(channel_id(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, term()}
  def set_variable(channel_id, name, value, timeout \\ 5_000)
      when is_binary(name) and is_binary(value) do
    body = Jason.encode!(%{"variable" => name, "value" => value})
    post("channels/" <> channel_id <> "/variable", body, timeout)
  end

  @doc "Exit the Stasis application and continue at context/extension/priority."
  @spec continue(channel_id(), String.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def continue(channel_id, context, extension, priority \\ 1, timeout \\ 5_000) do
    query =
      URI.encode_query(%{
        "context" => context,
        "extension" => extension,
        "priority" => Integer.to_string(priority)
      })

    post("channels/" <> channel_id <> "/continue?" <> query, ~c"", timeout)
  end

  @doc "Hang up the channel."
  @spec hangup(channel_id(), pos_integer()) :: :ok | {:error, term()}
  def hangup(channel_id, timeout \\ 5_000) do
    url = base_url() <> "/ari/channels/" <> channel_id

    case request(:delete, url, timeout) do
      {:ok, status, _body} when status in 200..299 -> :ok
      {:ok, status, _body} -> {:error, {:ari_http_status, status}}
      {:error, reason} -> {:error, {:ari_transport, reason}}
    end
  end

  # ─── internals ──────────────────────────────────────────────────────────────

  defp post(path, body, timeout) do
    url = base_url() <> "/ari/" <> path

    case request_with_body(:post, url, body, timeout) do
      {:ok, status, _body} when status in 200..299 -> :ok
      {:ok, status, body} -> {:error, {:ari_http_status, status, truncate(body)}}
      {:error, reason} -> {:error, {:ari_transport, reason}}
    end
  end

  defp request(method, url, timeout) do
    request_with_body(method, url, nil, timeout)
  end

  defp request_with_body(method, url, body, timeout) do
    headers = [{~c"authorization", String.to_charlist(basic_auth())}]
    http_opts = [timeout: timeout, connect_timeout: min(timeout, 5_000)]
    opts = [body_format: :binary]

    request =
      case body do
        nil -> {String.to_charlist(url), headers}
        _ -> {String.to_charlist(url), headers, ~c"application/json", body}
      end

    :httpc.request(method, request, http_opts, opts) |> normalize()
  end

  defp normalize({:ok, {{_version, status, _reason}, _headers, body}}) when is_binary(body) do
    {:ok, status, body}
  end

  defp normalize({:ok, {{_version, status, _reason}, _headers}}) do
    {:ok, status, ""}
  end

  defp normalize({:error, reason}), do: {:error, reason}

  defp config, do: Application.get_env(:voice_core, :ari, []) |> Map.new()

  defp base_url do
    url = config()[:url] || "http://127.0.0.1:8088"
    String.trim_trailing(url, "/")
  end

  defp basic_auth do
    user = config()[:user] || "voice_core"
    pass = config()[:pass] || ""
    "Basic " <> Base.encode64("#{user}:#{pass}")
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 200)
end
