defmodule Sadld.SessionPluginsTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol.Notification
  alias Sadld.{Session, SessionEvents}
  alias Sadld.Test.{StubPlugin, StubProvider, StubTools}

  @usage %{input_tokens: 1, output_tokens: 1}

  @plugin_tool %{name: "remember", description: "Remember a fact.", parameters: %{}}

  defp reply(text), do: {:ok, %{text: text, tool_calls: [], usage: @usage}}

  defp start_session(respond, plugin, opts \\ []) do
    {:ok, id} =
      Session.start(
        cwd: "/tmp/project",
        model: "stub-model",
        provider: {StubProvider, respond: respond, tools: [%{name: "read"}]},
        tools: {StubTools, run: fn _call, _cwd -> {:ok, "built-in"} end},
        system_prompt: Keyword.get(opts, :system_prompt, "base"),
        plugins: [{StubPlugin, plugin}]
      )

    :ok = SessionEvents.subscribe(id)
    id
  end

  # Waits for the end of `turn_id` and returns its stop reason.
  defp await_turn(turn_id) do
    receive do
      {:session_event, _id, %Notification{method: "turn.end", params: %{turn_id: ^turn_id} = p}} ->
        p.stop_reason
    after
      1_000 -> flunk("turn #{turn_id} did not end")
    end
  end

  # Forwards each event to the test process as `{:event, type, properties}`.
  defp events_to(pid), do: fn type, properties -> send(pid, {:event, type, properties}) end

  defp calls_once(call) do
    fn messages ->
      case List.last(messages) do
        %{role: :tool} -> reply("done")
        _user -> {:ok, %{text: "", tool_calls: [call], usage: @usage}}
      end
    end
  end

  test "a new session announces itself to its plugins, a resumed one does not" do
    id = start_session(fn _ -> reply("hi") end, event: events_to(self()))

    assert_receive {:event, "session.created", %{"info" => info}}
    assert %{"id" => ^id, "title" => "", "directory" => "/tmp/project"} = info
    assert %{"created" => created, "updated" => created} = info["time"]
    assert is_integer(created)

    :ok = GenServer.stop(Session.whereis(id))

    {:ok, _info} =
      Session.resume(id, provider: {StubProvider, respond: & &1}, tools: {StubTools, []})

    refute_receive {:event, "session.created", _properties}
  end

  test "plugin tools are offered to the model after the session's own" do
    test_pid = self()

    respond = fn _messages, _on_text, opts ->
      send(test_pid, {:tools, opts[:tools]})
      reply("hi")
    end

    id = start_session(respond, tools: fn -> [@plugin_tool] end)
    {:ok, turn_id} = Session.send_message(id, "hi")
    await_turn(turn_id)

    assert_received {:tools, [%{name: "read"}, @plugin_tool]}
  end

  test "a call to a plugin tool runs in the plugin" do
    test_pid = self()
    call = %{id: "call_1", name: "remember", args: %{"fact" => "x"}}

    run_tool = fn call, context ->
      send(test_pid, {:run_tool, call, context})
      {:error, "no room"}
    end

    id = start_session(calls_once(call), tools: fn -> [@plugin_tool] end, run_tool: run_tool)
    {:ok, turn_id} = Session.send_message(id, "remember x")
    assert await_turn(turn_id) == "completed"

    assert_received {:run_tool, ^call, context}
    assert context == %{session_id: id, turn_id: turn_id, cwd: "/tmp/project"}

    assert %{role: :tool, call_id: "call_1", content: "no room", is_error: true} in Session.messages(
             id
           )
  end

  test "the system prompt passes through the plugins before each model call" do
    test_pid = self()

    hook = fn
      "experimental.chat.system.transform", input, %{"system" => system} ->
        send(test_pid, {:transform, input})
        %{"system" => system ++ ["extra"]}

      _name, _input, output ->
        output
    end

    respond = fn messages, _on_text, opts ->
      send(test_pid, {:system, opts[:system]})
      calls_once(%{id: "c", name: "read", args: %{}}).(messages)
    end

    id = start_session(respond, hook: hook)
    {:ok, turn_id} = Session.send_message(id, "hi")
    await_turn(turn_id)

    assert_received {:transform, %{"sessionID" => ^id, "model" => %{"id" => "stub-model"}}}
    assert_received {:system, "base\n\nextra"}
    assert_received {:transform, _input}
    assert_received {:system, "base\n\nextra"}
  end

  test "text a plugin adds to the user's message follows it as messages of its own" do
    test_pid = self()

    hook = fn
      "chat.message", input, %{"parts" => [part]} = output ->
        send(test_pid, {:chat_message, input, output})
        note = Map.merge(part, %{"text" => "remember the tests", "synthetic" => true})
        %{output | "parts" => [part, note, %{part | "text" => "plain"}]}

      _name, _input, output ->
        output
    end

    respond = fn messages ->
      send(test_pid, {:messages, messages})
      reply("ok")
    end

    id = start_session(respond, hook: hook)
    {:ok, turn_id} = Session.send_message(id, "run the tests")
    await_turn(turn_id)

    assert_received {:chat_message, %{"sessionID" => ^id, "messageID" => ^turn_id}, output}

    assert %{"message" => %{"id" => ^turn_id, "sessionID" => ^id, "role" => "user"}} = output

    assert [%{"type" => "text", "text" => "run the tests", "messageID" => ^turn_id}] =
             output["parts"]

    injected = [
      %{role: :user, content: "run the tests"},
      %{role: :user, content: "remember the tests", synthetic: true},
      %{role: :user, content: "plain"}
    ]

    assert_received {:messages, ^injected}
    assert Enum.take(Session.messages(id), 3) == injected
  end

  test "tool results pass through the plugins before the model sees them" do
    test_pid = self()
    call = %{id: "call_1", name: "read", args: %{"path" => "a"}}

    hook = fn
      "tool.execute.after", input, output ->
        send(test_pid, {:after, input, output})
        %{output | "output" => output["output"] <> " (seen)"}

      _name, _input, output ->
        output
    end

    id = start_session(calls_once(call), hook: hook)
    {:ok, turn_id} = Session.send_message(id, "read a")
    await_turn(turn_id)

    assert_received {:after, input, output}

    assert input == %{
             "tool" => "read",
             "sessionID" => id,
             "callID" => "call_1",
             "args" => %{"path" => "a"}
           }

    assert output == %{"title" => "read", "output" => "built-in", "metadata" => %{}}

    assert %{role: :tool, call_id: "call_1", content: "built-in (seen)", is_error: false} in Session.messages(
             id
           )
  end

  test "a turn reports the session busy, then idle" do
    id = start_session(fn _ -> reply("hi") end, event: events_to(self()))
    {:ok, turn_id} = Session.send_message(id, "hi")
    await_turn(turn_id)

    assert_receive {:event, "session.status",
                    %{"sessionID" => ^id, "status" => %{"type" => "busy"}}}

    assert_receive {:event, "session.status",
                    %{"sessionID" => ^id, "status" => %{"type" => "idle"}}}

    assert_receive {:event, "session.idle", %{"sessionID" => ^id}}
  end

  test "a failed turn reports session.error before going idle" do
    id = start_session(fn _ -> {:error, :boom} end, event: events_to(self()))
    {:ok, turn_id} = Session.send_message(id, "hi")
    assert await_turn(turn_id) == "error"

    assert_receive {:event, "session.error", %{"sessionID" => ^id, "error" => error}}
    assert error == %{"name" => "UnknownError", "data" => %{"message" => ":boom"}}
    assert_receive {:event, "session.idle", %{"sessionID" => ^id}}
  end

  describe "send_message/3" do
    test "with :no_reply records the message without starting a turn" do
      id = start_session(fn _ -> flunk("no turn expected") end, [])

      assert Session.send_message(id, "note", no_reply: true, synthetic: true) == {:ok, nil}
      assert Session.messages(id) == [%{role: :user, content: "note", synthetic: true}]
      refute_receive {:session_event, ^id, _notification}
    end

    test "with :no_reply records the message even while a turn runs" do
      test_pid = self()

      respond = fn _messages ->
        send(test_pid, {:waiting, self()})

        receive do
          :go -> reply("hi")
        end
      end

      id = start_session(respond, [])
      {:ok, turn_id} = Session.send_message(id, "hi")
      assert_receive {:waiting, turn}

      assert Session.send_message(id, "aside", no_reply: true) == {:ok, nil}
      assert Session.send_message(id, "again") == {:error, :busy}
      send(turn, :go)
      await_turn(turn_id)

      assert Session.messages(id) == [
               %{role: :user, content: "hi"},
               %{role: :user, content: "aside"},
               %{role: :assistant, content: "hi", tool_calls: []}
             ]
    end

    test "with :synthetic starts a turn on a marked message" do
      id = start_session(fn _ -> reply("woken") end, [])

      {:ok, turn_id} = Session.send_message(id, "1 unread", synthetic: true)
      await_turn(turn_id)

      assert hd(Session.messages(id)) == %{role: :user, content: "1 unread", synthetic: true}
    end
  end
end
