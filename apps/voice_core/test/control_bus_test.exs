defmodule VoiceCore.ControlBusTest do
  @moduledoc """
  End-to-end (loopback HTTP) test of the brain→body bridge: a stub control_api
  returns `agent.speak` events, and the bus must forward them to the agent as
  `{:speak, text}` messages.
  """

  use ExUnit.Case, async: false

  alias VoiceCore.ControlBus

  # ─── Minimal HTTP/1.1 stub ──────────────────────────────────────────────────

  defp start_stub(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])

    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> accept_loop(listen, handler) end)
    {port, pid, listen}
  end

  defp accept_loop(listen, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, handler) end)
        accept_loop(listen, handler)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, handler) do
    case read_request_line(socket, "") do
      {:ok, path} ->
        {status, body} = handler.(path)
        reason = if status == 200, do: "OK", else: "Not Found"

        response =
          "HTTP/1.1 #{status} #{reason}\r\n" <>
            "content-type: application/json\r\n" <>
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

        :gen_tcp.send(socket, response)

      :error ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_request_line(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "\r\n") do
          [request_line | _] = String.split(acc, "\r\n")
          [_, path | _] = String.split(request_line, " ")
          {:ok, path}
        else
          read_request_line(socket, acc)
        end

      {:error, _} ->
        :error
    end
  end

  defp configure(port) do
    previous = Application.get_env(:voice_core, :control_api)

    Application.put_env(:voice_core, :control_api,
      enabled: true,
      base_url: "http://127.0.0.1:#{port}",
      token: "",
      request_timeout_ms: 2_000,
      poll_wait_ms: 10
    )

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:voice_core, :control_api),
        else: Application.put_env(:voice_core, :control_api, previous)
    end)
  end

  test "forwards agent.speak events to the agent" do
    body =
      Jason.encode!(%{
        "events" => [
          %{"seq" => 1, "type" => "agent.speak", "data" => %{"text" => "hello there"}}
        ],
        "cursor" => 1
      })

    {port, _pid, listen} = start_stub(fn _path -> {200, body} end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    configure(port)

    start_supervised!(
      {ControlBus, %{call_id: "call-bus-1", agent: self(), greeting: "fallback"}},
      restart: :temporary
    )

    assert_receive {:bridge, :attached}, 2_000
    assert_receive {:speak, "hello there"}, 2_000
  end

  test "greets locally and stops when the call is unknown to control_api" do
    {port, _pid, listen} = start_stub(fn _path -> {404, ~s({"error":"not_found"})} end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    configure(port)

    bus =
      start_supervised!(
        {ControlBus, %{call_id: "call-bus-2", agent: self(), greeting: "local greeting"}},
        restart: :temporary
      )

    ref = Process.monitor(bus)
    assert_receive {:bridge, :absent}, 2_000
    assert_receive {:speak, "local greeting"}, 2_000
    # The bus ends itself once it learns the call is not a control_api call.
    assert_receive {:DOWN, ^ref, :process, ^bus, :normal}, 2_000
  end

  test "an inbound call greets locally then stays bridged for OpenCode" do
    body =
      Jason.encode!(%{
        "events" => [
          %{"seq" => 1, "type" => "agent.speak", "data" => %{"text" => "opencode here"}}
        ],
        "cursor" => 1
      })

    {port, _pid, listen} = start_stub(fn _path -> {200, body} end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    configure(port)

    start_supervised!(
      {ControlBus,
       %{
         call_id: "call-bus-3",
         agent: self(),
         greeting: "local greeting",
         direction: :inbound
       }},
      restart: :temporary
    )

    assert_receive {:speak, "local greeting"}, 2_000
    assert_receive {:bridge, :attached}, 2_000
    assert_receive {:speak, "opencode here"}, 2_000
  end
end
