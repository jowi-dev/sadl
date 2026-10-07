defmodule Sadld.ListenerTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol
  alias Sadld.Test.{StubProvider, StubTools}

  @usage %{input_tokens: 1, output_tokens: 1}

  @fixtures_dir Path.expand("../../../protocol/fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "sadld-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "sadld.sock")}
  end

  defp start_listener(path, opts \\ []) do
    name = :"listener_#{System.unique_integer([:positive])}"
    spec = {Sadld.Listener, Keyword.merge([path: path, name: name], opts)}
    start_supervised(Supervisor.child_spec(spec, id: name))
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])

    socket
  end

  defp send_line(socket, line), do: :ok = :gen_tcp.send(socket, line <> "\n")

  defp request(socket, map) do
    send_line(socket, JSON.encode!(map))
    receive_message(socket)
  end

  defp receive_message(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
    assert String.ends_with?(line, "\n")
    JSON.decode!(line)
  end

  defp fixture(name), do: @fixtures_dir |> Path.join(name) |> File.read!() |> JSON.decode!()

  defp handshake(socket) do
    assert request(socket, fixture("handshake.request.json")) ==
             fixture("handshake.response.json")
  end

  defp error_code(%{"error" => %{"code" => code}}), do: code

  defp open(socket) do
    %{"result" => %{"id" => id}} = request(socket, fixture("session.open.request.no-model.json"))
    id
  end

  defp send_request(request_id, id, text),
    do: %{
      fixture("session.send.request.json")
      | "id" => request_id,
        "params" => %{"id" => id, "text" => text}
    }

  defp resume_request(id),
    do: put_in(fixture("session.resume.request.json"), ["params", "id"], id)

  defp cancel_request(request_id, id),
    do: %{fixture("session.cancel.request.json") | "id" => request_id, "params" => %{"id" => id}}

  # Reads notifications up to and including the next turn.end.
  defp receive_turn(socket, acc \\ []) do
    message = receive_message(socket)
    acc = [message | acc]
    if message["method"] == "turn.end", do: Enum.reverse(acc), else: receive_turn(socket, acc)
  end

  describe "with a running listener" do
    setup %{path: path} do
      {:ok, _pid} = start_listener(path)
      %{socket: connect(path)}
    end

    test "answers the handshake fixture with its response fixture", %{socket: socket} do
      handshake(socket)
    end

    test "rejects an unsupported protocol version", %{socket: socket} do
      request = put_in(fixture("handshake.request.json"), ["params", "protocol_version"], 99)

      assert request(socket, request) == fixture("handshake.response.version-mismatch.json")
    end

    test "requires a handshake before any other request", %{socket: socket} do
      response = request(socket, fixture("session.list.request.json"))

      assert %{"id" => 5} = response
      assert error_code(response) == -32_001
    end

    test "answers every request fixture with a response for its method", %{socket: socket} do
      handshake(socket)

      for name <- File.ls!(@fixtures_dir), String.contains?(name, ".request") do
        original = fixture(name)
        [method | _] = String.split(name, ".request")
        response = request(socket, original)

        assert response["id"] == original["id"], "#{name}: wrong id"

        assert {:ok, _} = Protocol.decode_response(response, method),
               "#{name}: undecodable response #{inspect(response)}"
      end
    end

    test "answers invalid JSON with a parse error and a null id", %{socket: socket} do
      send_line(socket, ~s({"jsonrpc": "2.0", "id": 1,))
      response = receive_message(socket)

      assert response["id"] == nil
      assert error_code(response) == -32_700
    end

    test "answers a non-object message with an invalid request error", %{socket: socket} do
      send_line(socket, JSON.encode!([fixture("handshake.request.json")]))
      response = receive_message(socket)

      assert response["id"] == nil
      assert error_code(response) == -32_600
    end

    test "echoes a readable id on an invalid request", %{socket: socket} do
      response = request(socket, %{"jsonrpc" => "2.0", "id" => 9, "method" => "handshake"})

      assert response["id"] == 9
      assert error_code(response) == -32_600
    end

    test "answers an unknown method with method not found", %{socket: socket} do
      handshake(socket)

      response =
        request(socket, %{"jsonrpc" => "2.0", "id" => 1, "method" => "nope", "params" => %{}})

      assert error_code(response) == -32_601
    end

    test "answers bad params with invalid params", %{socket: socket} do
      handshake(socket)

      response =
        request(socket, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "session.open",
          "params" => %{"cwd" => 1}
        })

      assert error_code(response) == -32_602
    end

    test "keeps each connection's handshake state separate", %{path: path, socket: socket} do
      handshake(socket)
      other = connect(path)

      response = request(other, fixture("session.list.request.json"))
      assert error_code(response) == -32_001
    end
  end

  describe "with sessions" do
    # The stub model echoes the user's text, except "wait", which blocks
    # until the turn is cancelled.
    setup %{path: path} do
      respond = fn messages ->
        case List.last(messages) do
          %{content: "wait"} ->
            receive do
              :never -> :ok
            end

          %{content: text} ->
            {:ok, %{text: "echo: " <> text, tool_calls: [], usage: @usage}}
        end
      end

      session = [
        provider: {StubProvider, respond: respond},
        tools: {StubTools, run: fn _call, _cwd -> {:ok, ""} end},
        model: "stub-default"
      ]

      {:ok, _pid} = start_listener(path, session: session)
      %{socket: connect(path)}
    end

    test "opens a session in cwd with the default model", %{socket: socket} do
      handshake(socket)

      assert %{"id" => 1, "result" => info} =
               request(socket, fixture("session.open.request.no-model.json"))

      assert %{"cwd" => "/home/u/proj", "model" => "stub-default"} = info
      assert is_binary(info["id"])
      assert {:ok, _, 0} = DateTime.from_iso8601(info["updated_at"])
    end

    test "opens a session with the requested model", %{socket: socket} do
      handshake(socket)
      %{"result" => info} = request(socket, fixture("session.open.request.json"))

      assert info["model"] == "glm-5.3-flash"
    end

    test "streams a turn's notifications after the send response", %{socket: socket} do
      handshake(socket)
      id = open(socket)

      assert %{"id" => 7, "result" => %{"turn_id" => turn_id}} =
               request(socket, send_request(7, id, "hi"))

      assert [
               %{"method" => "turn.delta", "params" => delta},
               %{"method" => "turn.end", "params" => turn_end}
             ] = receive_turn(socket)

      assert delta == %{"session_id" => id, "turn_id" => turn_id, "text" => "echo: hi"}
      assert turn_end["stop_reason"] == "completed"
    end

    test "every client attached to a session sees the same stream", %{path: path} = ctx do
      handshake(ctx.socket)
      id = open(ctx.socket)
      other = connect(path)
      handshake(other)

      assert %{"id" => 2, "result" => %{"id" => ^id, "cwd" => "/home/u/proj"}} =
               request(other, resume_request(id))

      %{"result" => %{"turn_id" => _}} = request(ctx.socket, send_request(3, id, "hi"))
      stream = receive_turn(ctx.socket)
      assert receive_turn(other) == stream

      %{"result" => %{"turn_id" => _}} = request(other, send_request(3, id, "again"))
      stream = receive_turn(other)
      assert receive_turn(ctx.socket) == stream
    end

    test "a client hears only the sessions it opened or attached to", %{path: path} = ctx do
      handshake(ctx.socket)
      id = open(ctx.socket)
      bystander = connect(path)
      handshake(bystander)
      open(bystander)

      %{"result" => _} = request(bystander, send_request(3, id, "hi"))
      receive_turn(ctx.socket)

      assert {:error, :timeout} = :gen_tcp.recv(bystander, 0, 100)
    end

    test "resuming an unknown session answers session not found", %{socket: socket} do
      handshake(socket)

      assert request(socket, fixture("session.resume.request.json")) ==
               fixture("session.resume.response.not-found.json")
    end

    test "send and cancel on an unknown session answer session not found", %{socket: socket} do
      handshake(socket)

      assert error_code(request(socket, fixture("session.send.request.json"))) == -32_002
      assert error_code(request(socket, fixture("session.cancel.request.json"))) == -32_002
    end

    test "a running turn makes send busy until it is cancelled", %{socket: socket} do
      handshake(socket)
      id = open(socket)

      %{"result" => %{"turn_id" => turn_id}} = request(socket, send_request(3, id, "wait"))
      assert error_code(request(socket, send_request(4, id, "hi"))) == -32_003

      assert request(socket, cancel_request(5, id)) == %{
               "jsonrpc" => "2.0",
               "id" => 5,
               "result" => %{}
             }

      assert [%{"method" => "turn.end", "params" => turn_end}] = receive_turn(socket)
      assert turn_end["turn_id"] == turn_id
      assert turn_end["stop_reason"] == "cancelled"
    end
  end

  test "rejects an overlong line and keeps the connection usable", %{path: path} do
    {:ok, _pid} = start_listener(path, max_line_length: 128)
    socket = connect(path)

    send_line(socket, ~s({"jsonrpc": "2.0", "id": 1, "pad": "#{String.duplicate("x", 300)}"}))
    response = receive_message(socket)

    assert response["id"] == nil
    assert error_code(response) == -32_600
    handshake(socket)
  end

  test "creates the socket readable and writable by its owner only", %{path: path} do
    {:ok, _pid} = start_listener(path)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "creates the socket's parent directory", %{path: path} do
    nested = Path.join([Path.dirname(path), "nested", "sadld.sock"])
    {:ok, _pid} = start_listener(nested)

    handshake(connect(nested))
  end

  test "replaces a stale socket file on boot", %{path: path} do
    {:ok, stale} = :gen_tcp.listen(0, ifaddr: {:local, path})
    :ok = :gen_tcp.close(stale)
    assert File.exists?(path)

    {:ok, _pid} = start_listener(path)
    handshake(connect(path))
  end

  test "refuses to replace a socket another server is listening on", %{path: path} do
    {:ok, _pid} = start_listener(path)

    assert {:error, reason} = start_listener(path)
    assert inspect(reason) =~ "eaddrinuse"
    handshake(connect(path))
  end

  test "removes the socket file when it stops", %{path: path} do
    {:ok, pid} = start_listener(path)
    :ok = Supervisor.stop(pid)

    refute File.exists?(path)
  end

  test "refuses a path too long for a Unix socket", %{path: path} do
    long = Path.join(Path.dirname(path), String.duplicate("x", 120) <> ".sock")

    assert {:error, reason} = start_listener(long)
    assert inspect(reason) =~ "path_too_long"
  end
end
