defmodule VoiceCore.AudioSocket.Server do
  @moduledoc """
  TCP server for AudioSocket media connections.

  Accepts one TCP connection per call (as Asterisk `chan_audiosocket` opens),
  gives each connection its own process (isolation under concurrency), parses
  AudioSocket frames, and routes audio/DTMF to the owning `VoiceCore.MediaSession`.

  Call binding:

    * **UUID flow (Asterisk `res_audiosocket`):** if the first frame received is
      a control frame whose payload is a printable UUID (from an AudioSocket URL
      query like `?uuid=<call_id>`), audio is routed to the `MediaSession`
      registered under `{:media, <uuid>}`.
    * **Explicit attach flow (tests / SDK):** `attach(call_id, pid)` binds a
      connection to a receiving process directly.

  Unattached/orphan audio is never buffered or queued — it is dropped and
  counted (`orphan_frames`). This guarantees call isolation (AGENTS.md rule 6).
  """

  use GenServer
  require Logger

  alias VoiceCore.MediaTransport.AudioSocket

  @type conn_id :: String.t()

  # ─── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Bound listen port (useful when configured with port 0 / ephemeral)."
  @spec port() :: pos_integer()
  def port, do: GenServer.call(__MODULE__, :port, 5_000)

  @doc """
  Binds an already-connected AudioSocket connection to a receiving process
  (a `VoiceCore.MediaSession`). Returns `:ok` or `{:error, :unknown_connection}`.
  """
  @spec attach(conn_id(), pid()) :: :ok | {:error, term()}
  def attach(conn_id, pid) do
    GenServer.call(__MODULE__, {:attach, conn_id, pid}, 5_000)
  end

  @doc "Detaches and closes a connection."
  @spec detach(conn_id()) :: :ok | {:error, term()}
  def detach(conn_id) do
    GenServer.call(__MODULE__, {:detach, conn_id}, 5_000)
  end

  @doc "Sends one PCM chunk on a connection (wraps it in an AudioSocket frame)."
  @spec send_audio(conn_id(), binary()) :: :ok | {:error, term()}
  def send_audio(conn_id, pcm) when is_binary(pcm) do
    GenServer.call(__MODULE__, {:send_audio, conn_id, pcm}, 5_000)
  end

  @doc "Server statistics."
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats, 5_000)

  @doc "Live map of connections."
  @spec connections() :: map()
  def connections, do: GenServer.call(__MODULE__, :connections, 5_000)

  # ─── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(config) do
    host = config[:host] || "127.0.0.1"
    port = config[:port] || 9019

    opts = [
      :binary,
      :inet,
      {:active, false},
      {:packet, :raw},
      {:reuseaddr, true},
      {:backlog, 128},
      {:nodelay, true}
    ]

    case :gen_tcp.listen(port, opts) do
      {:ok, listen_socket} ->
        {:ok, actual_port} = :inet.port(listen_socket)
        Logger.info("AudioSocket server listening on #{host}:#{actual_port}")

        # Acceptor runs monitored (not linked) so a crash never kills the server.
        {_pid, accept_ref} = spawn_monitor(fn -> accept_loop(listen_socket) end)

        state = %{
          host: host,
          port: actual_port,
          listen_socket: listen_socket,
          accept_ref: accept_ref,
          connections: %{},
          accepted_total: 0,
          orphan_frames: 0,
          frames_rx: 0,
          frames_tx: 0
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("AudioSocket listen failed on #{host}:#{port}: #{inspect(reason)}")
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:stats, _from, state) do
    {:reply, stats(state), state}
  end

  def handle_call(:connections, _from, state) do
    {:reply, state.connections, state}
  end

  def handle_call({:attach, conn_id, pid}, _from, state) when is_pid(pid) do
    case Map.fetch(state.connections, conn_id) do
      {:ok, conn} when is_pid(conn.pid) ->
        send(conn.pid, {:media_attach, pid})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unknown_connection}, state}
    end
  end

  def handle_call({:detach, conn_id}, _from, state) do
    case Map.fetch(state.connections, conn_id) do
      {:ok, conn} when is_pid(conn.pid) ->
        send(conn.pid, :close_connection)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unknown_connection}, state}
    end
  end

  def handle_call({:send_audio, conn_id, pcm}, _from, state) do
    case Map.fetch(state.connections, conn_id) do
      {:ok, conn} when is_pid(conn.pid) ->
        send(conn.pid, {:send_audio, pcm})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unknown_connection}, state}
    end
  end

  @impl true
  # New connection handed over from the acceptor: pid owns the socket.
  def handle_info({:accepted, conn_id, pid, peer}, state) do
    conn = %{
      pid: pid,
      peer: peer,
      uuid: nil,
      frames_rx: 0,
      frames_tx: 0,
      audio_frames: 0,
      orphan_frames: 0
    }

    final =
      if map_size(state.connections) >= 256 do
        # Bounded concurrency — refuse politely by closing the connection.
        send(pid, :close_connection)
        state
      else
        %{
          state
          | connections: Map.put(state.connections, conn_id, conn),
            accepted_total: state.accepted_total + 1
        }
      end

    {:noreply, final}
  end

  # Delta stats from a connection process (frames are added, not replaced).
  def handle_info({:conn_stats, conn_id, delta}, state) do
    case Map.fetch(state.connections, conn_id) do
      {:ok, conn} ->
        merged =
          Map.merge(conn, delta, fn
            _k, old, new when is_integer(old) and is_integer(new) -> old + new
            _k, _old, new -> new
          end)

        state = %{
          state
          | connections: Map.put(state.connections, conn_id, merged),
            frames_rx: state.frames_rx + Map.get(delta, :frames_rx, 0),
            frames_tx: state.frames_tx + Map.get(delta, :frames_tx, 0),
            orphan_frames: state.orphan_frames + Map.get(delta, :orphan_frames, 0)
        }

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:conn_closed, conn_id}, state) do
    {:noreply, %{state | connections: Map.delete(state.connections, conn_id)}}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    if ref == state.accept_ref and reason != :normal do
      Logger.error("AudioSocket acceptor died: #{inspect(reason)}; restarting")
      {_pid, accept_ref} = spawn_monitor(fn -> accept_loop(state.listen_socket) end)
      {:noreply, %{state | accept_ref: accept_ref}}
    else
      # Connection process died — sweep by pid for robustness.
      connections =
        state.connections
        |> Enum.reject(fn {_id, conn} -> conn.pid == pid end)
        |> Map.new()

      {:noreply, %{state | connections: connections}}
    end
  end

  def handle_info({:acceptor_failed, reason}, state) do
    Logger.error("AudioSocket accept failed: #{inspect(reason)}; restarting acceptor")
    {_pid, accept_ref} = spawn_monitor(fn -> accept_loop(state.listen_socket) end)
    {:noreply, %{state | accept_ref: accept_ref}}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("AudioSocket server shutting down: #{map_size(state.connections)} connections")
    Enum.each(state.connections, fn {_id, conn} -> send(conn.pid, :close_connection) end)
    :gen_tcp.close(state.listen_socket)
    :ok
  end

  # ─── Acceptor ───────────────────────────────────────────────────────────────

  # The acceptor *is* the controlling process of each accepted socket, so it
  # transfers ownership to a fresh per-connection process before notifying the
  # GenServer. The connection process only starts reading after ownership lands.
  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        conn_id = new_conn_id()
        {:ok, {ip, peer_port}} = :inet.peername(socket)

        {pid, _ref} = spawn_monitor(fn -> connection_await(socket, conn_id) end)
        server_pid = whereis(__MODULE__)

        case :gen_tcp.controlling_process(socket, pid) do
          :ok ->
            send(pid, {:ready, server_pid})
            send(server_pid, {:accepted, conn_id, pid, "#{inspect(ip)}:#{peer_port}"})

          {:error, reason} ->
            Logger.warning("AudioSocket transfer failed: #{inspect(reason)}")
            :gen_tcp.close(socket)
        end

        accept_loop(listen_socket)

      {:error, reason} ->
        server_pid = whereis(__MODULE__)
        if is_pid(server_pid), do: send(server_pid, {:acceptor_failed, reason})
        exit(:normal)
    end
  end

  defp whereis(name), do: Process.whereis(name) || name

  # ─── Per-connection loop ────────────────────────────────────────────────────

  # Waits until the acceptor has transferred the socket, then owns it.
  defp connection_await(socket, conn_id) do
    receive do
      {:ready, server_pid} ->
        :ok = :inet.setopts(socket, active: :once)
        # handshake_done = false until the first frame is classified.
        receive_loop(conn_id, nil, nil, false, socket, server_pid, <<>>)

      :close_connection ->
        :gen_tcp.close(socket)
        :ok
    end
  end

  # Fully event-driven per-connection loop: no blocking reads, so attach and
  # audio are handled with zero added latency. The first frame may be a control
  # frame carrying a UUID (Asterisk res_audiosocket `?uuid=<call_id>`); that is
  # classified by `resolve_handshake/5`.
  defp receive_loop(conn_id, uuid, attached, handshake_done, socket, server_pid, buffer) do
    receive do
      {:tcp, ^socket, data} ->
        {uuid, handshake_done, buffer} =
          if handshake_done do
            {uuid, true, buffer <> data}
          else
            resolve_handshake(conn_id, uuid, buffer <> data, server_pid)
          end

        {remaining, deltas} = process_frames(conn_id, uuid, attached, buffer)
        send(server_pid, {:conn_stats, conn_id, deltas})
        :ok = :inet.setopts(socket, active: :once)
        receive_loop(conn_id, uuid, attached, handshake_done, socket, server_pid, remaining)

      {:tcp_closed, ^socket} ->
        send(server_pid, {:conn_closed, conn_id})
        :ok

      {:tcp_error, ^socket, reason} ->
        Logger.debug("AudioSocket #{conn_id} tcp error: #{inspect(reason)}")
        send(server_pid, {:conn_closed, conn_id})
        :ok

      {:media_attach, pid} ->
        Logger.info("AudioSocket #{conn_id}: media attached to #{inspect(pid)}")

        # Replay any buffered frames now that a receiver exists.
        {remaining, deltas} = process_frames(conn_id, uuid, pid, buffer)
        send(server_pid, {:conn_stats, conn_id, deltas})
        :ok = :inet.setopts(socket, active: :once)
        receive_loop(conn_id, uuid, pid, handshake_done, socket, server_pid, remaining)

      {:send_audio, pcm} ->
        case AudioSocket.create_audio_frame(pcm) do
          {:ok, frame} ->
            case :gen_tcp.send(socket, frame) do
              :ok ->
                send(server_pid, {:conn_stats, conn_id, %{frames_tx: 1}})

              {:error, reason} ->
                Logger.debug("AudioSocket #{conn_id} tx error: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.warning("AudioSocket #{conn_id} tx dropped: #{inspect(reason)}")
        end

        :ok = :inet.setopts(socket, active: :once)
        receive_loop(conn_id, uuid, attached, handshake_done, socket, server_pid, buffer)

      :close_connection ->
        :gen_tcp.close(socket)
        send(server_pid, {:conn_closed, conn_id})
        :ok
    end
  end

  # Classifies the first frame. If it is a control frame with a printable UUID,
  # adopt it as the routing key (real Asterisk flow); otherwise leave the buffer
  # intact so it is parsed as ordinary audio/DTMF.
  defp resolve_handshake(conn_id, uuid, buffer, server_pid) do
    case AudioSocket.parse(buffer) do
      {:ok, %{type: :control, payload: payload}, remaining} ->
        if printable_uuid?(payload) do
          Logger.info("AudioSocket connection #{conn_id} bound via UUID #{payload}")
          send(server_pid, {:conn_stats, conn_id, %{uuid: payload}})
          {payload, true, remaining}
        else
          {uuid, true, buffer}
        end

      {:error, :incomplete, _} ->
        {uuid, false, buffer}

      _ ->
        {uuid, true, buffer}
    end
  end

  # Parses all complete frames in the buffer and routes them to the call's
  # MediaSession (audio) or the same session for DTMF. Returns
  # {remaining_buffer, deltas}.
  defp process_frames(conn_id, uuid, attached, buffer) do
    case AudioSocket.parse_multiple(buffer) do
      {:ok, frames, remaining} ->
        deltas =
          Enum.reduce(frames, %{frames_rx: 0, audio_frames: 0, orphan_frames: 0}, fn frame, acc ->
            case route_frame(conn_id, uuid, attached, frame) do
              {:audio, sent?} ->
                %{
                  acc
                  | frames_rx: acc.frames_rx + 1,
                    audio_frames: acc.audio_frames + if(sent?, do: 1, else: 0),
                    orphan_frames: acc.orphan_frames + if(sent?, do: 0, else: 1)
                }

              {:dtmf, _} ->
                %{acc | frames_rx: acc.frames_rx + 1}

              :other ->
                %{acc | frames_rx: acc.frames_rx + 1}
            end
          end)

        {remaining, deltas}

      {:error, :incomplete, remaining} ->
        {remaining, %{frames_rx: 0, audio_frames: 0, orphan_frames: 0}}

      {:error, reason, remaining} ->
        Logger.warning("AudioSocket #{conn_id} parse error: #{inspect(reason)}")
        {remaining, %{frames_rx: 0, audio_frames: 0, orphan_frames: 0}}
    end
  end

  defp route_frame(conn_id, uuid, attached, %{type: :audio, payload: pcm}) do
    case media_pid_for(uuid, conn_id, attached) do
      nil ->
        {:audio, false}

      pid ->
        send(pid, {:audio_frame_rx, pcm})
        {:audio, true}
    end
  end

  defp route_frame(conn_id, uuid, attached, %{type: :dtmf, payload: digit}) do
    case media_pid_for(uuid, conn_id, attached) do
      nil ->
        {:dtmf, :unattached}

      pid ->
        send(pid, {:dtmf_frame, :binary.bin_to_list(digit)})
        {:dtmf, pid}
    end
  end

  defp route_frame(_conn_id, _uuid, _attached, _frame), do: :other

  # Binding order: an explicitly attached receiver first (SDK/tests and
  # MediaSession.attach_transport), then the UUID from the AudioSocket URL
  # (real Asterisk flow), then the TCP connection id.
  defp media_pid_for(uuid, conn_id, attached) do
    cond do
      is_pid(attached) ->
        attached

      true ->
        keys = if uuid, do: [{:media, uuid}, {:media, conn_id}], else: [{:media, conn_id}]

        Enum.find_value(keys, fn key ->
          case Registry.lookup(VoiceCore.CallRegistry, key) do
            [{pid, _}] -> pid
            [] -> nil
          end
        end)
    end
  end

  defp stats(state) do
    %{
      host: state.host,
      port: state.port,
      connections: map_size(state.connections),
      accepted_total: state.accepted_total,
      frames_rx: state.frames_rx,
      frames_tx: state.frames_tx,
      orphan_frames: state.orphan_frames,
      audio_frames:
        Enum.reduce(state.connections, 0, fn {_id, c}, acc -> acc + c.audio_frames end)
    }
  end

  defp printable_uuid?(payload) do
    byte_size(payload) in 8..64 and String.printable?(payload) and
      Regex.match?(~r/^[A-Za-z0-9\-_]+$/, payload)
  end

  defp new_conn_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
