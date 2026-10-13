defmodule Sadld.SessionChildrenTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol.Notification
  alias Sadld.{Permissions, Session, SessionEvents, Store}
  alias Sadld.Test.{StubPlugin, StubProvider, StubTools}

  @usage %{input_tokens: 1, output_tokens: 1}

  defp reply(text), do: {:ok, %{text: text, tool_calls: [], usage: @usage}}

  defp start_session(respond, opts \\ []) do
    {:ok, policy} = Permissions.parse(Keyword.get(opts, :policy, %{"default" => "allow"}))

    {:ok, id} =
      Session.start(
        cwd: "/tmp/project",
        model: "stub-model",
        provider: {StubProvider, respond: respond},
        tools: {StubTools, run: fn _call, _cwd -> {:ok, "ran"} end},
        permissions: policy,
        system_prompt: "base",
        plugins: [{StubPlugin, Keyword.get(opts, :plugin, [])}]
      )

    id
  end

  defp await_turn(id, turn_id) do
    receive do
      {:session_event, ^id, %Notification{method: "turn.end", params: %{turn_id: ^turn_id} = p}} ->
        p.stop_reason
    after
      1_000 -> flunk("turn #{turn_id} did not end")
    end
  end

  defp events_to(pid),
    do: [event: fn type, properties -> send(pid, {:event, type, properties}) end]

  # Replies after one call to `read`, so each turn runs one tool.
  defp reads_once(test_pid) do
    fn messages ->
      send(test_pid, {:request, messages})

      case List.last(messages) do
        %{role: :tool} ->
          reply("read it")

        _user ->
          {:ok, %{text: "", tool_calls: [%{id: "c", name: "read", args: %{}}], usage: @usage}}
      end
    end
  end

  describe "create_child/1" do
    test "starts a child that inherits its parent's setup" do
      parent =
        start_session(reads_once(self()),
          policy: %{"default" => "deny"},
          plugin: events_to(self())
        )

      assert_receive {:event, "session.created", %{"info" => %{"id" => ^parent} = info}}
      refute Map.has_key?(info, "parentID")

      assert {:ok, child} = Session.create_child(parent)
      assert child != parent

      assert_receive {:event, "session.created", %{"info" => %{"id" => ^child} = info}}
      assert %{"parentID" => ^parent, "directory" => "/tmp/project"} = info

      assert {:ok, %{parent_id: ^parent, cwd: "/tmp/project", model: "stub-model"}} =
               Store.fetch_session(child)

      :ok = SessionEvents.subscribe(child)
      {:ok, turn_id} = Session.send_message(child, "read")
      await_turn(child, turn_id)

      assert_received {:request, [%{role: :user, content: "read"}]}

      assert %{role: :tool, content: "permission denied by policy"} =
               Enum.find(Session.messages(child), &(&1.role == :tool))
    end

    test "fails for a parent that is not running" do
      assert Session.create_child("missing") == {:error, :not_found}
    end
  end

  test "list leaves child sessions out" do
    parent = start_session(fn _ -> reply("hi") end)
    {:ok, child} = Session.create_child(parent)

    ids = Enum.map(Session.list(), & &1.id)
    assert parent in ids
    refute child in ids
  end

  test "a call a child's policy asks about is denied rather than left waiting" do
    parent = start_session(reads_once(self()), policy: %{"default" => "ask"})
    {:ok, child} = Session.create_child(parent)
    :ok = SessionEvents.subscribe(child)

    {:ok, turn_id} = Session.send_message(child, "read")
    assert await_turn(child, turn_id) == "completed"

    refute_received {:session_event, ^child, %Notification{method: "permission.request"}}

    assert %{role: :tool, is_error: true, content: "permission denied by policy: " <> _reason} =
             Enum.find(Session.messages(child), &(&1.role == :tool))
  end

  describe "delete/1" do
    test "stops a session and its children and forgets them" do
      test_pid = self()

      hang = fn _messages ->
        send(test_pid, {:waiting, self()})
        Process.sleep(:infinity)
      end

      parent = start_session(hang, plugin: events_to(self()))
      {:ok, child} = Session.create_child(parent)
      {:ok, grandchild} = Session.create_child(child)
      {:ok, _turn_id} = Session.send_message(child, "work")
      assert_receive {:waiting, turn}
      turn_ref = Process.monitor(turn)

      assert Session.delete(parent) == :ok

      assert_receive {:DOWN, ^turn_ref, :process, _pid, _reason}

      for id <- [parent, child, grandchild] do
        assert Session.whereis(id) == nil
        assert Store.fetch_session(id) == {:error, :not_found}
        assert_receive {:event, "session.deleted", %{"info" => %{"id" => ^id}}}
      end

      assert Session.delete(parent) == {:error, :not_found}
    end

    test "deletes a stored session that is not running" do
      id = start_session(fn _ -> reply("hi") end)
      :ok = GenServer.stop(Session.whereis(id))

      assert Session.delete(id) == :ok
      assert Store.fetch_session(id) == {:error, :not_found}
    end
  end

  describe "prompt/3" do
    test "runs a turn and answers with its final reply" do
      id = start_session(reads_once(self()))
      {:ok, nil} = Session.send_message(id, "note", no_reply: true)

      assert Session.prompt(id, "read", synthetic: true) == {:ok, %{seq: 4, text: "read it"}}
      assert Enum.at(Session.messages(id), 1) == %{role: :user, content: "read", synthetic: true}
    end

    test "fails when the turn fails" do
      id = start_session(fn _ -> {:error, :boom} end)

      assert Session.prompt(id, "hi") == {:error, {:failed, ":boom"}}
    end

    test "fails at once on a busy session, so a hook prompting its own session cannot deadlock" do
      test_pid = self()

      hook = fn
        "chat.message", %{"sessionID" => id}, output ->
          send(test_pid, {:prompted, Session.prompt(id, "again")})
          output

        _name, _input, output ->
          output
      end

      id = start_session(fn _ -> reply("hi") end, plugin: [hook: hook])

      assert Session.prompt(id, "hi") == {:ok, %{seq: 1, text: "hi"}}
      assert_received {:prompted, {:error, :busy}}
      assert Session.prompt("missing", "hi") == {:error, :not_found}
    end
  end
end
