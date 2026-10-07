defmodule Sadld.Listener do
  @moduledoc """
  Listens on the server's Unix domain socket and runs one
  `Sadld.Connection` per accepted client.

  A supervisor over a `DynamicSupervisor` of connections and an acceptor
  that owns the listening socket. On boot the acceptor creates the socket's
  parent directory, replaces a stale socket file left by a server that is
  no longer running, and refuses to start (`:eaddrinuse`) if another server
  still answers on the path, or (`{:path_too_long, path}`) if the path does
  not fit in a Unix socket address. The socket is made readable and
  writable by its owner only, and is removed when the listener stops.

  The application starts a listener on `default_path/0` unless the `:sadld`
  `:listen` environment is `false`, as it is in tests.

  ## Options

    * `:path` - the socket path, `default_path/0` if absent
    * `:name` - the supervisor name, `Sadld.Listener` if absent
    * `:max_line_length` - longest request line in bytes; longer lines are
      answered with an invalid request error (default 1 MiB)
    * `:session` - how clients' sessions are started; see
      `Sadld.Connection.start_link/1`
  """

  use Supervisor

  @doc "Starts the listener. See the module docs for options."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "The socket path from `docs/protocol.md`: `$XDG_RUNTIME_DIR/sadl/sadld.sock`."
  @spec default_path() :: Path.t()
  def default_path do
    case System.get_env("XDG_RUNTIME_DIR") do
      dir when dir in [nil, ""] -> raise "XDG_RUNTIME_DIR is not set; cannot place sadld.sock"
      dir -> Path.join([dir, "sadl", "sadld.sock"])
    end
  end

  @impl true
  def init(opts) do
    connections = Module.concat(opts[:name], Connections)

    acceptor_opts =
      opts
      |> Keyword.put_new_lazy(:path, &default_path/0)
      |> Keyword.put(:connections, connections)

    children = [
      {DynamicSupervisor, name: connections, strategy: :one_for_one},
      {Sadld.Listener.Acceptor, acceptor_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
