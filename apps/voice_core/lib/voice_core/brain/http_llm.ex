defmodule VoiceCore.Brain.HTTPLLM do
  @moduledoc """
  `VoiceCore.Brain` implementation that asks the platform `llm` service over
  HTTP (the service's provider interface; Ollama/Groq/etc).

  Uses OTP `:httpc` (no extra dependencies) with an explicit timeout; any
  failure (timeout, non-200, unparseable body) becomes a structured error.

  The system prompt keeps replies short and speech-friendly: TTS synthesis and
  playback time both scale with reply length, so a chatty model is the main
  cause of growing per-turn latency. The agent also clamps spoken replies
  (`AGENT_MAX_REPLY_CHARS`) as a hard backstop.
  """

  @behaviour VoiceCore.Brain

  @base_system_prompt """
  You are a voice assistant on a live phone call. Your reply is spoken aloud by
  text-to-speech, so use plain prose only: no markdown, no lists, no headings,
  no emoji, no stage directions. Answer in one or two short sentences (about 30
  words maximum) and ask a brief follow-up question when that is natural.
  """

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
    @base_system_prompt <> "\n(Current call id: #{call_id}.)"
  end

  defp system_prompt(_context), do: @base_system_prompt

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"response" => text}} when is_binary(text) -> {:ok, String.trim(text)}
      {:ok, %{"choices" => [%{"message" => %{"content" => text}}]}} -> {:ok, String.trim(text)}
      {:ok, %{"choices" => [%{"text" => text}]}} -> {:ok, String.trim(text)}
      {:ok, _} -> {:error, :unexpected_llm_payload}
      {:error, _} -> {:error, :invalid_llm_json}
    end
  end
end
