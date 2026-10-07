defmodule Sadld.Connection do
  @moduledoc """
  One client connection on the server socket.

  Reads newline-delimited JSON requests (the socket is in `packet: :line`
  mode) and answers each in order with exactly one response, as described
  in `docs/protocol.md`. The first request must be `handshake`; any other
  request before a successful handshake gets error `-32001`.

  `session.open` starts a `Sadld.Session` and `session.resume` attaches to
  a running one; both subscribe the connection to the session's
  `Sadld.SessionEvents` topic, and every notification on it is written to
  the socket. Several connections can attach to one session and each sees
  the whole stream. `session.send` and `session.cancel` work on any running
  session. Resuming a session that is not running, and `session.list`, wait
  on persistence and answer with session not found and an internal error.
  """

  use GenServer, restart: :temporary

  alias Sadld.{Protocol, Session, SessionEvents}
  alias Sadld.Protocol.{Notification, Request, Response}
  alias Sadld.Provider.OpenAI

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  @unsupported_version -32_000
  @handshake_required -32_001
  @session_not_found -32_002
  @session_busy -32_003

  @doc """
  Starts a connection for an accepted socket. The caller must make the new
  process the socket's controlling process and then call `activate/1`.

  ## Options

    * `:socket` (required) - the accepted client socket
    * `:session` - how `session.open` starts sessions, as `:provider` and
      `:tools` for `Sadld.Session.start/1` and `:model`, the model used when
      the request names none. Missing keys default to the OpenAI provider
      offered `Sadld.Tools`, and the provider's configured model.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Starts reading from the socket once this process controls it."
  @spec activate(pid()) :: :ok
  def activate(pid), do: GenServer.cast(pid, :activate)

  @impl true
  def init(opts) do
    state = %{
      socket: Keyword.fetch!(opts, :socket),
      session: Keyword.merge(default_session(), opts[:session] || []),
      handshaken?: false,
      overflow?: false
    }

    {:ok, state}
  end

  defp default_session do
    config = Application.get_env(:sadld, OpenAI, [])

    [
      provider: {OpenAI, tools: Sadld.Tools.specs()},
      tools: {Sadld.Tools, []},
      model: Keyword.get(config, :model, OpenAI.default_model())
    ]
  end

  @impl true
  def handle_cast(:activate, state), do: {:noreply, read_next(state)}

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    {:noreply, state |> handle_data(data) |> read_next()}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:stop, :normal, state}

  def handle_info({:session_event, _id, %Notification{} = notification}, state) do
    write(state, notification)
    {:noreply, state}
  end

  defp read_next(state) do
    :inet.setopts(state.socket, active: :once)
    state
  end

  # A chunk without a trailing newline is part of a line longer than the
  # socket buffer. Drop the line and answer once it ends.
  defp handle_data(state, data) do
    cond do
      not String.ends_with?(data, "\n") ->
        %{state | overflow?: true}

      state.overflow? ->
        write(state, error(nil, @invalid_request, "line too long"))
        %{state | overflow?: false}

      true ->
        {response, state} = handle_line(data, state)
        write(state, response)
        state
    end
  end

  defp handle_line(line, state) do
    with {:ok, message} <- decode_json(line),
         {:ok, request} <- decode_request(message) do
      dispatch(request, state)
    else
      {:error, response} -> {response, state}
    end
  end

  defp decode_json(line) do
    case JSON.decode(line) do
      {:ok, message} -> {:ok, message}
      {:error, _reason} -> {:error, error(nil, @parse_error, "parse error")}
    end
  end

  defp decode_request(message) do
    case Protocol.decode_request(message) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {code, text} = describe(reason)
        {:error, error(readable_id(message), code, text)}
    end
  end

  defp describe(:invalid_request), do: {@invalid_request, "invalid request"}
  defp describe(:method_not_found), do: {@method_not_found, "method not found"}

  defp describe({:invalid_params, path}),
    do: {@invalid_params, "invalid params: " <> Enum.join(path, ".")}

  defp readable_id(%{"id" => id}) when is_integer(id) and id >= 0, do: id
  defp readable_id(_message), do: nil

  defp dispatch(%Request{method: "handshake", id: id, params: params}, state) do
    version = Protocol.version()

    if params.protocol_version == version do
      result = %{protocol_version: version}
      {%Response{id: id, method: "handshake", result: result}, %{state | handshaken?: true}}
    else
      data = %{"supported" => [version]}
      {error(id, @unsupported_version, "unsupported protocol version", data), state}
    end
  end

  defp dispatch(%Request{id: id}, %{handshaken?: false} = state),
    do: {error(id, @handshake_required, "handshake required"), state}

  defp dispatch(%Request{method: "session.open", id: id, params: params} = request, state) do
    opts = [
      cwd: params.cwd,
      model: Map.get(params, :model, state.session[:model]),
      provider: state.session[:provider],
      tools: state.session[:tools]
    ]

    case Session.start(opts) do
      {:ok, session_id} -> {attach(request, session_id), state}
      {:error, reason} -> {error(id, @internal_error, inspect(reason)), state}
    end
  end

  defp dispatch(%Request{method: "session.resume", params: %{id: session_id}} = request, state),
    do: {attach(request, session_id), state}

  defp dispatch(%Request{method: "session.send", id: id, params: params}, state) do
    case Session.send_message(params.id, params.text) do
      {:ok, turn_id} -> {result(id, "session.send", %{turn_id: turn_id}), state}
      {:error, reason} -> {session_error(id, reason), state}
    end
  end

  defp dispatch(%Request{method: "session.cancel", id: id, params: params}, state) do
    case Session.cancel(params.id) do
      :ok -> {result(id, "session.cancel", %{}), state}
      {:error, reason} -> {session_error(id, reason), state}
    end
  end

  defp dispatch(%Request{id: id}, state),
    do: {error(id, @internal_error, "not implemented"), state}

  # Subscribes before reading the info so no notification falls between
  # the two; the response still goes out before any of them is written.
  defp attach(%Request{id: id, method: method}, session_id) do
    :ok = SessionEvents.subscribe(session_id)

    case Session.info(session_id) do
      {:error, reason} ->
        SessionEvents.unsubscribe(session_id)
        session_error(id, reason)

      info ->
        result(id, method, %{info | updated_at: DateTime.to_iso8601(info.updated_at)})
    end
  end

  defp session_error(id, :not_found), do: error(id, @session_not_found, "session not found")
  defp session_error(id, :busy), do: error(id, @session_busy, "session busy")

  defp result(id, method, result), do: %Response{id: id, method: method, result: result}

  defp error(id, code, message, data \\ nil) do
    %Response{id: id, error: %{code: code, message: message, data: data}}
  end

  defp write(state, message) do
    :gen_tcp.send(state.socket, [JSON.encode!(Protocol.to_map(message)), ?\n])
  end
end
