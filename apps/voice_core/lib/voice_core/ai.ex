defmodule VoiceCore.AI do
  @moduledoc """
  Thin, dependency-free HTTP client for the platform's Python AI services
  (STT/TTS/LLM). Every call carries an explicit timeout (AGENTS.md rule 7) and
  returns structured results — never raises across the boundary.

  Contracts (see `packages/contracts`):

    * STT  `POST /v1/transcribe` body = raw 16-bit **little-endian** PCM
           (`audio/pcm`, WAV-compatible); response `{"text": ...}`
    * TTS  `POST /v1/synthesize`  body = JSON `{"text": ...}`; response raw
           16-bit **big-endian** PCM (`audio/pcm`)

  The core keeps PCM big-endian internally, so `transcribe/2` converts to
  little-endian at this boundary (`synthesize/2` already receives big-endian).
  """

  require Logger

  @spec transcribe(binary(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(pcm, timeout_ms \\ 15_000) do
    url = service_url(:stt_url, "http://127.0.0.1:5001")

    # Internal PCM is big-endian; the STT service consumes little-endian PCM.
    pcm = VoiceCore.PCM.swap16(pcm)

    case post_binary(url <> "/v1/transcribe", pcm, timeout_ms) do
      {:ok, 200, body} -> decode_text(body)
      {:ok, status, _} -> {:error, {:stt_http_status, status}}
      {:error, reason} -> {:error, {:stt_transport, reason}}
    end
  end

  @spec synthesize(String.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def synthesize(text, timeout_ms \\ 15_000) when is_binary(text) do
    url = service_url(:tts_url, "http://127.0.0.1:5003")

    body = Jason.encode!(%{"text" => text})

    case post_json(url <> "/v1/synthesize", body, timeout_ms) do
      {:ok, 200, audio} -> {:ok, audio}
      {:ok, status, _body} -> {:error, {:tts_http_status, status}}
      {:error, reason} -> {:error, {:tts_transport, reason}}
    end
  end

  # ─── internals ──────────────────────────────────────────────────────────────

  defp service_url(key, default) do
    Application.get_env(:voice_core, :ai, [])[key] || default
  end

  defp post_binary(url, payload, timeout_ms) do
    request = {String.to_charlist(url), [], ~c"audio/pcm", payload}
    http_opts = [timeout: timeout_ms, connect_timeout: min(timeout_ms, 5_000)]

    :httpc.request(:post, request, http_opts, body_format: :binary)
    |> ok_tuple()
  end

  defp post_json(url, json, timeout_ms) do
    request = {String.to_charlist(url), [], ~c"application/json", json}
    http_opts = [timeout: timeout_ms, connect_timeout: min(timeout_ms, 5_000)]

    :httpc.request(:post, request, http_opts, body_format: :binary)
    |> ok_tuple()
  end

  # :httpc returns {:ok, {{status, reason}, headers, body}} on the happy path,
  # already a {status, body} triple for us here.
  defp ok_tuple({:ok, {{_version, status, _reason}, _headers, body}}), do: {:ok, status, body}
  defp ok_tuple({:error, reason}), do: {:error, reason}

  defp decode_text(body) do
    case Jason.decode(body) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, String.trim(text)}
      {:ok, _} -> {:error, :unexpected_stt_payload}
      {:error, _} -> {:error, :invalid_stt_json}
    end
  end
end
