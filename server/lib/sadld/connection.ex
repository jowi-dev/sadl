defmodule Sadld.Connection do
  @moduledoc """
  One client connection on the server socket.

  Reads newline-delimited JSON requests (the socket is in `packet: :line`
  mode) and answers each in order with exactly one response, as described
  in `docs/protocol.md`. The first request must be `handshake`; any other
  request before a successful handshake gets error `-32001`.

  Session methods are not implemented yet and answer with an internal
  error.
  """

  use GenServer, restart: :temporary

  alias Sadld.Protocol
  alias Sadld.Protocol.{Request, Response}

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  @unsupported_version -32_000
  @handshake_required -32_001

  @doc """
  Starts a connection for an accepted socket. The caller must make the new
  process the socket's controlling process and then call `activate/1`.
  """
  @spec start_link(:gen_tcp.socket()) :: GenServer.on_start()
  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @doc "Starts reading from the socket once this process controls it."
  @spec activate(pid()) :: :ok
  def activate(pid), do: GenServer.cast(pid, :activate)

  @impl true
  def init(socket), do: {:ok, %{socket: socket, handshaken?: false, overflow?: false}}

  @impl true
  def handle_cast(:activate, state), do: {:noreply, read_next(state)}

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    {:noreply, state |> handle_data(data) |> read_next()}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:stop, :normal, state}

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
        reply(state, error(nil, @invalid_request, "line too long"))
        %{state | overflow?: false}

      true ->
        {response, state} = handle_line(data, state)
        reply(state, response)
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

  defp dispatch(%Request{id: id}, state),
    do: {error(id, @internal_error, "not implemented"), state}

  defp error(id, code, message, data \\ nil) do
    %Response{id: id, error: %{code: code, message: message, data: data}}
  end

  defp reply(state, response) do
    :gen_tcp.send(state.socket, [JSON.encode!(Protocol.to_map(response)), ?\n])
  end
end
