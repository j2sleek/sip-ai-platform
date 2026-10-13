defmodule VoiceCore.Brain.HTTPLLM do
  @moduledoc """
  `VoiceCore.Brain` implementation that asks the platform `llm` service over
  HTTP (Ollama behind the service's provider interface).

  Uses OTP `:httpc` (no extra dependencies) with an explicit timeout; any
  failure (timeout, non-200, unparseable body) becomes a structured error.
  """

  @behaviour VoiceCore.Brain

  @spec new(keyword()) :: :ok
  def new(_opts), do: :ok

  @impl true
  def respond(transcript, context, timeout_ms) do
    url =
      (Application.get_env(:voice_core, :ai, [])[:llm_url] || "http://127.0.0.1:5002") <>
        "/v1/generate"

    body =
      Jason.encode!(%{
        "messages" => [
          %{"role" => "system", "content" => system_prompt(context)},
          %{"role" => "user", "content" => transcript}
        ]
      })

    request = {String.to_charlist(url), [], ~c"application/json", body}
    http_opts = [timeout: timeout_ms, connect_timeout: min(timeout_ms, 5_000)]
    opts = [body_format: :binary]

    case :httpc.request(:post, request, http_opts, opts) do
      {:ok, {{_version, 200, _reason}, _headers, response_body}} ->
        parse_response(response_body)

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:llm_http_status, status}}

      {:error, reason} ->
        {:error, {:llm_transport, reason}}
    end
  end

  defp system_prompt(%{call_id: call_id}) when is_binary(call_id) do
    "You are the voice agent on call #{call_id}. Reply with a short, natural " <>
      "spoken response (1-3 sentences). No markdown."
  end

  defp system_prompt(_context) do
    "You are the voice agent. Reply with a short, natural spoken response (1-3 sentences). No markdown."
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"response" => text}} when is_binary(text) -> {:ok, String.trim(text)}
      {:ok, %{"choices" => [%{"message" => %{"content" => text}}]}} -> {:ok, String.trim(text)}
      {:ok, %{"choices" => [%{"text" => text}]}} -> {:ok, String.trim(text)}
      {:ok, _other} -> {:error, :unexpected_llm_payload}
      {:error, _} -> {:error, :invalid_llm_json}
    end
  end
end
