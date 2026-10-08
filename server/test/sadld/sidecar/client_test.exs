defmodule Sadld.Sidecar.ClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sadld.Protocol.Notification
  alias Sadld.{Session, SessionEvents}
  alias Sadld.Sidecar.Client
  alias Sadld.Test.{StubProvider, StubTools}

  @moduletag :tmp_dir

  @usage %{input_tokens: 1, output_tokens: 1}

  defp start_session(
         cwd,
         respond \\ fn _ -> {:ok, %{text: "hi", tool_calls: [], usage: @usage}} end
       ) do
    {:ok, id} =
      Session.start(
        cwd: cwd,
        model: "m",
        provider: {StubProvider, respond: respond},
        tools: {StubTools, run: fn _call, _cwd -> {:ok, "ok"} end},
        system_prompt: "s"
      )

    :ok = SessionEvents.subscribe(id)
    id
  end

  defp await_turn(turn_id) do
    assert_receive {:session_event, _id,
                    %Notification{method: "turn.end", params: %{turn_id: ^turn_id}}}
  end

  defp path(id), do: %{"path" => %{"id" => id}}

  defp text(text), do: %{"type" => "text", "text" => text}

  test "session.get describes a stored session", %{tmp_dir: dir} do
    id = start_session(dir)

    assert {:ok, %{"id" => ^id, "title" => "", "directory" => ^dir, "time" => time}} =
             Client.handle("session.get", path(id), dir)

    assert is_integer(time["updated"])

    assert Client.handle("session.get", path("missing"), dir) ==
             {:error, -32_002, "session not found"}
  end

  test "session.list gives the sessions working in the worktree", %{tmp_dir: dir} do
    inside = start_session(Path.join(dir, "sub"))
    root = start_session(dir)
    _outside = start_session(dir <> "-other")

    assert {:ok, sessions} = Client.handle("session.list", %{}, dir)
    assert sessions |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort([inside, root])
  end

  test "session.status gives each running session in the worktree", %{tmp_dir: dir} do
    test_pid = self()

    respond = fn _messages ->
      send(test_pid, {:waiting, self()})

      receive do
        :go -> {:ok, %{text: "hi", tool_calls: [], usage: @usage}}
      end
    end

    busy = start_session(dir, respond)
    idle = start_session(dir)
    _elsewhere = start_session(dir <> "-other")
    {:ok, turn_id} = Session.send_message(busy, "hi")
    assert_receive {:waiting, turn}

    assert Client.handle("session.status", %{}, dir) ==
             {:ok, %{busy => %{"type" => "busy"}, idle => %{"type" => "idle"}}}

    send(turn, :go)
    await_turn(turn_id)
  end

  test "session.messages gives the text of each message, tool traffic left out", %{tmp_dir: dir} do
    call = %{id: "c", name: "read", args: %{}}

    respond = fn messages ->
      case List.last(messages) do
        %{role: :tool} -> {:ok, %{text: "done", tool_calls: [], usage: @usage}}
        _user -> {:ok, %{text: "", tool_calls: [call], usage: @usage}}
      end
    end

    id = start_session(dir, respond)
    {:ok, nil} = Session.send_message(id, "note", no_reply: true, synthetic: true)
    {:ok, turn_id} = Session.send_message(id, "read")
    await_turn(turn_id)

    assert Client.handle("session.messages", path(id), dir) ==
             {:ok,
              [
                %{
                  "info" => %{"id" => id <> "_0", "sessionID" => id, "role" => "user"},
                  "parts" => [%{"type" => "text", "text" => "note", "synthetic" => true}]
                },
                %{
                  "info" => %{"id" => id <> "_1", "sessionID" => id, "role" => "user"},
                  "parts" => [text("read")]
                },
                %{
                  "info" => %{"id" => id <> "_4", "sessionID" => id, "role" => "assistant"},
                  "parts" => [text("done")]
                }
              ]}

    assert Client.handle("session.messages", path("missing"), dir) ==
             {:error, -32_002, "session not found"}
  end

  test "session.prompt with noReply records the parts as one message", %{tmp_dir: dir} do
    id = start_session(dir)
    parts = [text("a"), Map.put(text("b"), "synthetic", true)]
    params = Map.put(path(id), "body", %{"noReply" => true, "parts" => parts})

    assert Client.handle("session.prompt", params, dir) ==
             {:ok,
              %{
                "info" => %{"sessionID" => id, "role" => "user"},
                "parts" => [%{"type" => "text", "text" => "a\n\nb", "synthetic" => true}]
              }}

    assert Session.messages(id) == [%{role: :user, content: "a\n\nb", synthetic: true}]
  end

  test "session.promptAsync without noReply starts a turn", %{tmp_dir: dir} do
    id = start_session(dir)
    params = Map.put(path(id), "body", %{"parts" => [text("wake up")]})

    assert Client.handle("session.promptAsync", params, dir) == {:ok, %{}}
    assert_receive {:session_event, ^id, %Notification{method: "turn.end"}}
    assert [%{role: :user, content: "wake up"}, %{role: :assistant}] = Session.messages(id)
  end

  test "prompting a busy session fails unless noReply", %{tmp_dir: dir} do
    test_pid = self()

    respond = fn _messages ->
      send(test_pid, {:waiting, self()})

      receive do
        :go -> {:ok, %{text: "hi", tool_calls: [], usage: @usage}}
      end
    end

    id = start_session(dir, respond)
    {:ok, turn_id} = Session.send_message(id, "hi")
    assert_receive {:waiting, turn}

    params = Map.put(path(id), "body", %{"parts" => [text("more")]})
    assert Client.handle("session.prompt", params, dir) == {:error, -32_003, "session busy"}

    unknown = Map.put(path("missing"), "body", %{"parts" => [text("x")]})
    assert Client.handle("session.prompt", unknown, dir) == {:error, -32_002, "session not found"}

    send(turn, :go)
    await_turn(turn_id)
  end

  test "tui.showToast logs the message", %{tmp_dir: dir} do
    params = %{"body" => %{"message" => "recalled 2 memories", "variant" => "info"}}

    log =
      capture_log([level: :info], fn ->
        assert Client.handle("tui.showToast", params, dir) == {:ok, true}
      end)

    assert log =~ "recalled 2 memories"
  end

  test "other methods and malformed params are refused", %{tmp_dir: dir} do
    assert Client.handle("session.create", %{"body" => %{}}, dir) ==
             {:error, -32_601, "method not found"}

    assert Client.handle("session.get", %{}, dir) == {:error, -32_602, "invalid params"}
  end
end
