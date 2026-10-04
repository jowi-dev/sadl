defmodule Sadld.ListenerTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol

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
