defmodule Sadld.Listener.Acceptor do
  @moduledoc false
  # Owns the listening socket. A linked loop process blocks in accept and
  # hands each client socket to a new Sadld.Connection, leaving this
  # process free to answer the supervisor.

  use GenServer

  @default_max_line_length 1_048_576

  # sun_path holds 108 bytes on Linux, including the terminating NUL.
  @max_path_bytes 107

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    connections = Keyword.fetch!(opts, :connections)
    max_line_length = Keyword.get(opts, :max_line_length, @default_max_line_length)

    with :ok <- check_length(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- remove_stale(path),
         {:ok, socket} <- listen(path, max_line_length) do
      Process.flag(:trap_exit, true)
      loop = spawn_link(fn -> accept_loop(socket, connections) end)
      {:ok, %{socket: socket, path: path, loop: loop}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, loop, reason}, %{loop: loop} = state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, %{socket: socket, path: path}) do
    :gen_tcp.close(socket)
    File.rm(path)
  end

  defp check_length(path) do
    if byte_size(path) <= @max_path_bytes, do: :ok, else: {:error, {:path_too_long, path}}
  end

  defp remove_stale(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :other}} ->
        case :gen_tcp.connect({:local, path}, 0, [], 1_000) do
          {:ok, probe} ->
            :gen_tcp.close(probe)
            {:error, :eaddrinuse}

          {:error, _reason} ->
            File.rm(path)
        end

      {:ok, _stat} ->
        {:error, :eexist}

      error ->
        error
    end
  end

  defp listen(path, max_line_length) do
    opts = [
      :binary,
      ifaddr: {:local, path},
      packet: :line,
      buffer: max_line_length,
      active: false
    ]

    with {:ok, socket} <- :gen_tcp.listen(0, opts) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, socket}

        error ->
          :gen_tcp.close(socket)
          error
      end
    end
  end

  defp accept_loop(listen_socket, connections) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        hand_off(socket, connections)
        accept_loop(listen_socket, connections)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end

  defp hand_off(socket, connections) do
    case DynamicSupervisor.start_child(connections, {Sadld.Connection, socket}) do
      {:ok, pid} ->
        :ok = :gen_tcp.controlling_process(socket, pid)
        Sadld.Connection.activate(pid)

      _error ->
        :gen_tcp.close(socket)
    end
  end
end
