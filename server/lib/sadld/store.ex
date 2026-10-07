defmodule Sadld.Store do
  @moduledoc """
  SQLite persistence for sessions and their messages.

  One process owns the database connection, so writes are serialized. Each
  session row holds its id, cwd, model and timestamps; its messages are kept
  in order, tool calls and tool results included, so a session can be
  rebuilt after its process or the whole server restarts.

  Calls that fail to write crash the store rather than return an error, so
  a caller never acknowledges data that was not persisted.

  The application starts the store at `:sadld` `:store_path`, or at
  `default_path/0` when that is not set.

  ## Options

    * `:path` (required) - the database file; its directory is created
    * `:name` - the process name, `Sadld.Store` if absent; `nil` for none
  """

  use GenServer

  alias Exqlite.Sqlite3

  @typedoc "The `SessionInfo` of `docs/protocol.md`. `updated_at` is RFC 3339 UTC."
  @type session_info :: %{
          id: String.t(),
          cwd: String.t(),
          model: String.t(),
          updated_at: String.t()
        }

  @schema [
    """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      cwd TEXT NOT NULL,
      model TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS messages (
      session_id TEXT NOT NULL REFERENCES sessions (id),
      seq INTEGER NOT NULL,
      role TEXT NOT NULL,
      data TEXT NOT NULL,
      PRIMARY KEY (session_id, seq)
    )
    """
  ]

  @session_columns "id, cwd, model, updated_at"

  @doc "Starts the store. See the module docs for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The database path: `$XDG_DATA_HOME/sadl/sadl.db`, with `XDG_DATA_HOME`
  defaulting to `~/.local/share` as the XDG base directory spec says.
  """
  @spec default_path() :: Path.t()
  def default_path do
    data_home =
      case System.get_env("XDG_DATA_HOME") do
        dir when dir in [nil, ""] -> Path.join(System.user_home!(), ".local/share")
        dir -> dir
      end

    Path.join([data_home, "sadl", "sadl.db"])
  end

  @doc "Records a new session with no messages and returns its info."
  @spec create_session(GenServer.server(), %{id: String.t(), cwd: String.t(), model: String.t()}) ::
          {:ok, session_info()}
  def create_session(store \\ __MODULE__, session),
    do: GenServer.call(store, {:create_session, session})

  @doc "Returns the info of session `id`."
  @spec fetch_session(GenServer.server(), String.t()) ::
          {:ok, session_info()} | {:error, :not_found}
  def fetch_session(store \\ __MODULE__, id), do: GenServer.call(store, {:fetch_session, id})

  @doc "Returns every session, most recently updated first."
  @spec list_sessions(GenServer.server()) :: [session_info()]
  def list_sessions(store \\ __MODULE__), do: GenServer.call(store, :list_sessions)

  @doc """
  Appends `messages` to session `id` in one transaction and marks the
  session updated. Returns once they are on disk.
  """
  @spec append_messages(GenServer.server(), String.t(), [Sadld.Provider.message()]) :: :ok
  def append_messages(store \\ __MODULE__, id, messages),
    do: GenServer.call(store, {:append_messages, id, messages})

  @doc "Returns session `id`'s messages, oldest first; `[]` for an unknown id."
  @spec messages(GenServer.server(), String.t()) :: [Sadld.Provider.message()]
  def messages(store \\ __MODULE__, id), do: GenServer.call(store, {:messages, id})

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 closes the database on shutdown.
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Sqlite3.open(path)

    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys = ON")
    Enum.each(@schema, &(:ok = Sqlite3.execute(conn, &1)))

    {:ok, %{conn: conn, last_timestamp: nil}}
  end

  @impl true
  def terminate(_reason, %{conn: conn}), do: Sqlite3.close(conn)

  @impl true
  def handle_call({:create_session, session}, _from, state) do
    {now, state} = timestamp(state)

    query(state.conn, "INSERT INTO sessions VALUES (?1, ?2, ?3, ?4, ?4)", [
      session.id,
      session.cwd,
      session.model,
      now
    ])

    {:reply, {:ok, Map.put(Map.take(session, [:id, :cwd, :model]), :updated_at, now)}, state}
  end

  def handle_call({:fetch_session, id}, _from, state) do
    case query(state.conn, "SELECT #{@session_columns} FROM sessions WHERE id = ?1", [id]) do
      [row] -> {:reply, {:ok, session_info(row)}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_sessions, _from, state) do
    rows =
      query(
        state.conn,
        "SELECT #{@session_columns} FROM sessions ORDER BY updated_at DESC, rowid DESC",
        []
      )

    {:reply, Enum.map(rows, &session_info/1), state}
  end

  def handle_call({:append_messages, id, messages}, _from, state) do
    {now, state} = timestamp(state)
    conn = state.conn

    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    try do
      [[next]] =
        query(conn, "SELECT COALESCE(MAX(seq) + 1, 0) FROM messages WHERE session_id = ?1", [id])

      messages
      |> Enum.with_index(next)
      |> Enum.each(fn {message, seq} ->
        {role, data} = encode_message(message)
        query(conn, "INSERT INTO messages VALUES (?1, ?2, ?3, ?4)", [id, seq, role, data])
      end)

      query(conn, "UPDATE sessions SET updated_at = ?2 WHERE id = ?1", [id, now])
      :ok = Sqlite3.execute(conn, "COMMIT")
    rescue
      error ->
        Sqlite3.execute(conn, "ROLLBACK")
        reraise error, __STACKTRACE__
    end

    {:reply, :ok, state}
  end

  def handle_call({:messages, id}, _from, state) do
    rows =
      query(state.conn, "SELECT role, data FROM messages WHERE session_id = ?1 ORDER BY seq", [
        id
      ])

    {:reply, Enum.map(rows, fn [role, data] -> decode_message(role, data) end), state}
  end

  # Runs one statement and returns its rows; crashes on any failure.
  defp query(conn, sql, args) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, args)
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      Sqlite3.release(conn, statement)
    end
  end

  # The current time as RFC 3339 UTC, strictly after the previous one handed
  # out, so `list_sessions/1` orders by update even within a microsecond.
  defp timestamp(state) do
    now = DateTime.utc_now()

    now =
      if state.last_timestamp && DateTime.compare(now, state.last_timestamp) != :gt,
        do: DateTime.add(state.last_timestamp, 1, :microsecond),
        else: now

    {DateTime.to_iso8601(now), %{state | last_timestamp: now}}
  end

  defp session_info([id, cwd, model, updated_at]),
    do: %{id: id, cwd: cwd, model: model, updated_at: updated_at}

  defp encode_message(%{role: :user, content: content}),
    do: {"user", JSON.encode!(%{content: content})}

  defp encode_message(%{role: :assistant, content: content, tool_calls: tool_calls}),
    do: {"assistant", JSON.encode!(%{content: content, tool_calls: tool_calls})}

  defp encode_message(%{role: :tool} = message),
    do: {"tool", JSON.encode!(Map.take(message, [:call_id, :content, :is_error]))}

  defp decode_message("user", data) do
    %{"content" => content} = JSON.decode!(data)
    %{role: :user, content: content}
  end

  defp decode_message("assistant", data) do
    %{"content" => content, "tool_calls" => tool_calls} = JSON.decode!(data)

    tool_calls =
      Enum.map(tool_calls, fn %{"id" => id, "name" => name, "args" => args} ->
        %{id: id, name: name, args: args}
      end)

    %{role: :assistant, content: content, tool_calls: tool_calls}
  end

  defp decode_message("tool", data) do
    %{"call_id" => call_id, "content" => content, "is_error" => is_error} = JSON.decode!(data)
    %{role: :tool, call_id: call_id, content: content, is_error: is_error}
  end
end
