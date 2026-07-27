defmodule VoiceCore.AudioSocket.Server do
  @moduledoc """
  TCP server for AudioSocket connections.

  Listens on 127.0.0.1:9019 and handles AudioSocket protocol connections
  from Asterisk. Manages connection lifecycle, frame parsing, and audio
  distribution to call sessions.
  """

  use GenServer

  require Logger

  alias VoiceCore.MediaTransport.AudioSocket

  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    Logger.info("AudioSocket server starting on #{config.host}:#{config.port}")

    # Start TCP listener
    try do
      {:ok, listen_socket} = :gen_tcp.listen(config.port, [:binary, :inet, {:active, false}, {:packet, :raw}, {:reuseaddr, true}, {:backlog, 100}])

      # Store config and socket in state
      state = %{
        config: config,
        listen_socket: listen_socket,
        connections: %{}
      }

      # Start accepting connections
      accept_connections(listen_socket)

      Logger.info("AudioSocket server listening on port #{config.port}")
      {:ok, state}
    rescue
      error ->
        Logger.error("Failed to start AudioSocket listener: #{Exception.message(error)}")
        {:stop, :listen_failed}
    end
  end

  @impl true
  def handle_info({:tcp, socket, ip, port}, state) do
    Logger.debug("New AudioSocket connection from #{ip}:#{port}")
    spawn_link(fn -> handle_connection(socket, ip, port, state.config) end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      connections: map_size(state.connections),
      config: state.config
    }
    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("AudioSocket server shutting down")
    :gen_tcp.close(state.listen_socket)
    :ok
  end

  defp accept_connections(listen_socket) do
    Task.start_link(fn ->
      loop_accept(listen_socket)
    end)
  end

  defp loop_accept(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        {:ok, {ip, port, _}} = :inet.peername(socket)
        send(self(), {:tcp, socket, ip, port})
        loop_accept(listen_socket)
      {:error, reason} ->
        Logger.error("AudioSocket accept failed: #{inspect(reason)}")
        :timer.sleep(1000)
        loop_accept(listen_socket)
    end
  end

  defp handle_connection(socket, ip, port, _config) do
    # Set socket options
    :ok = :gen_tcp.setopts(socket, [active: false])

    # Generate connection ID
    connection_id = :crypto.strong_rand_bytes(8) |> Base.encode16()

    Logger.info("AudioSocket connection established: #{connection_id} from #{ip}:#{port}")

    # Read and parse frames
    try do
      read_loop(socket, connection_id)
    rescue
      error ->
        Logger.error("AudioSocket connection #{connection_id} error: #{Exception.message(error)}")
    after
      :gen_tcp.close(socket)
      Logger.info("AudioSocket connection terminated: #{connection_id}")
    end
  end

  defp read_loop(socket, connection_id) do
    read_loop(socket, connection_id, <<>>, 0, 0)
  end

  defp read_loop(socket, connection_id, buffer, frames_received, bytes_received) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        new_buffer = buffer <> data
        bytes_received = bytes_received + byte_size(data)

        case AudioSocket.parse_multiple(new_buffer) do
          {:ok, frames, remaining} ->
            # Process parsed frames
            process_frames(connection_id, frames)

            # Continue with remaining buffer
            new_frames = frames_received + length(frames)
            read_loop(socket, connection_id, remaining, new_frames, bytes_received)

          {:error, :incomplete, remaining} ->
            # Need more data, keep buffer
            read_loop(socket, connection_id, remaining, frames_received, bytes_received)

          {:error, reason, remaining} ->
            Logger.error("AudioSocket #{connection_id} parse error: #{reason}")
            read_loop(socket, connection_id, remaining, frames_received, bytes_received)
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("AudioSocket #{connection_id} recv error: #{inspect(reason)}")
        :ok
    end
  end

  defp process_frames(connection_id, frames) do
    Enum.each(frames, fn frame ->
      case frame.type do
        :audio ->
          Logger.debug("AudioSocket #{connection_id}: audio frame, #{frame.length} bytes")
        :dtmf ->
          digit = :binary.bin_to_list(frame.payload)
          Logger.debug("AudioSocket #{connection_id}: DTMF digit '#{digit}'")
        :control ->
          Logger.debug("AudioSocket #{connection_id}: control frame, #{frame.length} bytes")
        :unknown ->
          Logger.warning("AudioSocket #{connection_id}: unknown frame type")
      end
    end)
  end

  @doc """
  Get server statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Get the server configuration.
  """
  def config do
    %{
      host: "127.0.0.1",
      port: 9019
    }
  end
end
