defmodule Sadld.SessionTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol.Notification
  alias Sadld.{Session, SessionEvents, Store}
  alias Sadld.Test.{StubProvider, StubTools}

  @usage %{input_tokens: 3, output_tokens: 2}

  defp reply(text), do: {:ok, %{text: text, tool_calls: [], usage: @usage}}

  defp session_opts(respond, opts \\ []) do
    run = Keyword.get(opts, :run, fn _call, _cwd -> {:ok, "ok"} end)

    [
      provider: {StubProvider, respond: respond},
      tools: {StubTools, run: run}
    ]
  end

  defp start_session(respond, opts \\ []) do
    {:ok, id} =
      Session.start([cwd: "/tmp/project", model: "stub-model"] ++ session_opts(respond, opts))

    :ok = SessionEvents.subscribe(id)
    id
  end

  # Collects notifications for `turn_id` up to and including its turn.end.
  defp collect_turn(turn_id, acc \\ []) do
    receive do
      {:session_event, _id, %Notification{params: %{turn_id: ^turn_id}} = n} ->
        if n.method == "turn.end",
          do: Enum.reverse([n | acc]),
          else: collect_turn(turn_id, [n | acc])

      {:session_event, _id, %Notification{method: "error"} = n} ->
        collect_turn(turn_id, [n | acc])
    after
      1_000 -> flunk("turn #{turn_id} did not end; got #{inspect(Enum.reverse(acc))}")
    end
  end

  # Forwards everything this process receives to `pid`, tagged `:watcher`.
  defp relay(pid) do
    receive do
      message -> send(pid, {:watcher, message})
    end

    relay(pid)
  end

  test "start registers the session under a fresh id" do
    id = start_session(fn _ -> reply("hi") end)
    other = start_session(fn _ -> reply("hi") end)

    assert id != other
    assert is_pid(Session.whereis(id))
    assert Session.whereis("missing") == nil
  end

  test "info describes the session and when its messages last changed" do
    id = start_session(fn _ -> reply("hi") end)

    assert %{id: ^id, cwd: "/tmp/project", model: "stub-model", updated_at: started} =
             Session.info(id)

    assert %DateTime{time_zone: "Etc/UTC"} = started

    {:ok, turn_id} = Session.send_message(id, "hi")
    collect_turn(turn_id)

    assert DateTime.compare(Session.info(id).updated_at, started) in [:gt, :eq]
    assert Session.info("missing") == {:error, :not_found}
  end

  test "a turn without tool calls streams the reply and completes" do
    id = start_session(fn _ -> reply("hello") end)

    assert {:ok, turn_id} = Session.send_message(id, "hi")

    assert [
             %Notification{method: "turn.delta", params: delta},
             %Notification{method: "turn.end", params: turn_end}
           ] = collect_turn(turn_id)

    assert delta == %{session_id: id, turn_id: turn_id, text: "hello"}

    assert turn_end == %{
             session_id: id,
             turn_id: turn_id,
             stop_reason: "completed",
             usage: @usage
           }

    assert Session.messages(id) == [
             %{role: :user, content: "hi"},
             %{role: :assistant, content: "hello", tool_calls: []}
           ]
  end

  test "every subscriber to the session sees the same stream" do
    id = start_session(fn _ -> reply("hello") end)
    test_pid = self()

    spawn_link(fn ->
      :ok = SessionEvents.subscribe(id)
      send(test_pid, :subscribed)
      relay(test_pid)
    end)

    assert_receive :subscribed
    {:ok, turn_id} = Session.send_message(id, "hi")

    for notification <- collect_turn(turn_id) do
      assert_receive {:watcher, {:session_event, ^id, ^notification}}
    end
  end

  test "text the provider streams reaches subscribers chunk by chunk" do
    respond = fn _messages, on_text ->
      on_text.("hel")
      on_text.("lo")
      reply("hello")
    end

    id = start_session(respond)

    {:ok, turn_id} = Session.send_message(id, "hi")

    assert [
             %Notification{method: "turn.delta", params: %{text: "hel"}},
             %Notification{method: "turn.delta", params: %{text: "lo"}},
             %Notification{method: "turn.end"}
           ] = collect_turn(turn_id)

    assert List.last(Session.messages(id)) == %{
             role: :assistant,
             content: "hello",
             tool_calls: []
           }
  end

  test "tool calls run and their results feed back until the model stops" do
    call = %{id: "call_1", name: "read", args: %{"path" => "a.txt"}}

    respond = fn messages ->
      case List.last(messages) do
        %{role: :user} -> {:ok, %{text: "", tool_calls: [call], usage: @usage}}
        %{role: :tool, content: "contents"} -> reply("done")
      end
    end

    run = fn %{name: "read"}, "/tmp/project" -> {:ok, "contents"} end
    id = start_session(respond, run: run)

    {:ok, turn_id} = Session.send_message(id, "read a.txt")

    assert [
             %Notification{method: "tool.call", params: tool_call},
             %Notification{method: "tool.result", params: tool_result},
             %Notification{method: "turn.delta", params: %{text: "done"}},
             %Notification{method: "turn.end", params: turn_end}
           ] = collect_turn(turn_id)

    assert tool_call == %{
             session_id: id,
             turn_id: turn_id,
             call_id: "call_1",
             name: "read",
             args: %{"path" => "a.txt"}
           }

    assert tool_result == %{
             session_id: id,
             turn_id: turn_id,
             call_id: "call_1",
             output: "contents",
             is_error: false
           }

    assert turn_end.stop_reason == "completed"
    assert turn_end.usage == %{input_tokens: 6, output_tokens: 4}

    assert Session.messages(id) == [
             %{role: :user, content: "read a.txt"},
             %{role: :assistant, content: "", tool_calls: [call]},
             %{role: :tool, call_id: "call_1", content: "contents", is_error: false},
             %{role: :assistant, content: "done", tool_calls: []}
           ]
  end

  test "a failing tool reports is_error and the turn continues" do
    call = %{id: "call_1", name: "bash", args: %{}}

    respond = fn messages ->
      case List.last(messages) do
        %{role: :user} -> {:ok, %{text: "", tool_calls: [call], usage: @usage}}
        %{role: :tool, is_error: true} -> reply("it failed")
      end
    end

    id = start_session(respond, run: fn _, _ -> {:error, "boom"} end)
    {:ok, turn_id} = Session.send_message(id, "go")

    notifications = collect_turn(turn_id)

    assert %Notification{params: %{output: "boom", is_error: true}} =
             Enum.find(notifications, &(&1.method == "tool.result"))

    assert List.last(notifications).params.stop_reason == "completed"
  end

  test "a provider error sends error then ends the turn with stop_reason error" do
    id = start_session(fn _ -> {:error, :timeout} end)
    {:ok, turn_id} = Session.send_message(id, "hi")

    assert [
             %Notification{method: "error", params: %{session_id: ^id, code: -32_603}},
             %Notification{method: "turn.end", params: turn_end}
           ] = collect_turn(turn_id)

    assert turn_end.stop_reason == "error"
    assert turn_end.usage == %{input_tokens: 0, output_tokens: 0}
  end

  @tag :capture_log
  test "a crashing turn ends with stop_reason error and leaves the session usable" do
    respond = fn messages ->
      if length(messages) == 1, do: raise("provider bug"), else: reply("recovered")
    end

    id = start_session(respond)
    pid = Session.whereis(id)

    {:ok, turn_id} = Session.send_message(id, "first")
    assert List.last(collect_turn(turn_id)).params.stop_reason == "error"

    {:ok, turn_id} = Session.send_message(id, "second")
    assert List.last(collect_turn(turn_id)).params.stop_reason == "completed"
    assert Session.whereis(id) == pid
  end

  describe "while a turn is running" do
    setup do
      test_pid = self()

      respond = fn _messages ->
        send(test_pid, {:provider_called, self()})

        receive do
          :release -> reply("late")
        end
      end

      id = start_session(respond)
      {:ok, turn_id} = Session.send_message(id, "hi")
      assert_receive {:provider_called, provider_pid}

      %{id: id, turn_id: turn_id, provider_pid: provider_pid}
    end

    test "send_message reports the session busy", %{id: id} do
      assert Session.send_message(id, "again") == {:error, :busy}
    end

    test "cancel stops the turn and frees the session", ctx do
      ref = Process.monitor(ctx.provider_pid)

      assert Session.cancel(ctx.id) == :ok

      assert [%Notification{method: "turn.end", params: turn_end}] = collect_turn(ctx.turn_id)
      assert turn_end.stop_reason == "cancelled"
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert Session.messages(ctx.id) == [%{role: :user, content: "hi"}]
      assert {:ok, _turn_id} = Session.send_message(ctx.id, "again")
    end
  end

  test "cancel with no running turn does nothing" do
    id = start_session(fn _ -> reply("hi") end)

    assert Session.cancel(id) == :ok
    refute_receive {:session_event, ^id, _}
  end

  test "calls on an unknown session return :not_found" do
    assert Session.send_message("missing", "hi") == {:error, :not_found}
    assert Session.cancel("missing") == {:error, :not_found}
    assert Session.messages("missing") == {:error, :not_found}
  end

  test "killing one session leaves its siblings working" do
    victim = start_session(fn _ -> reply("never") end)
    sibling = start_session(fn _ -> reply("still here") end)

    victim_pid = Session.whereis(victim)
    sibling_pid = Session.whereis(sibling)
    ref = Process.monitor(victim_pid)

    Process.exit(victim_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^victim_pid, :killed}

    assert Session.whereis(sibling) == sibling_pid
    {:ok, turn_id} = Session.send_message(sibling, "you ok?")

    assert [_delta, %Notification{method: "turn.end", params: %{stop_reason: "completed"}}] =
             collect_turn(turn_id)
  end

  describe "persistence" do
    test "start records the session in the store" do
      id = start_session(fn _ -> reply("hi") end)

      assert {:ok, %{id: ^id, cwd: "/tmp/project", model: "stub-model"}} =
               Store.fetch_session(id)

      assert id in Enum.map(Session.list(), & &1.id)
    end

    test "the user message is stored before send_message returns" do
      id =
        start_session(fn _ ->
          receive do
            :release -> reply("late")
          end
        end)

      {:ok, _turn_id} = Session.send_message(id, "hi")

      assert Store.messages(id) == [%{role: :user, content: "hi"}]
    end

    test "every message of a turn is stored, tool calls and results included" do
      call = %{id: "call_1", name: "read", args: %{"path" => "a.txt"}}

      respond = fn messages ->
        case List.last(messages) do
          %{role: :user} -> {:ok, %{text: "", tool_calls: [call], usage: @usage}}
          %{role: :tool} -> reply("done")
        end
      end

      id = start_session(respond)
      {:ok, turn_id} = Session.send_message(id, "read a.txt")
      collect_turn(turn_id)

      assert length(Store.messages(id)) == 4
      assert Store.messages(id) == Session.messages(id)
    end

    test "a restarted session rebuilds its messages from the store" do
      id = start_session(fn _ -> reply("hello") end)
      {:ok, turn_id} = Session.send_message(id, "hi")
      collect_turn(turn_id)
      before = Session.messages(id)

      pid = Session.whereis(id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      wait_until(fn -> Session.whereis(id) not in [nil, pid] end, "session #{id} not restarted")
      assert Session.messages(id) == before
    end
  end

  describe "resume" do
    test "starts a stopped session from the store with its history" do
      test_pid = self()

      id = start_session(fn _ -> reply("hello") end)
      {:ok, turn_id} = Session.send_message(id, "hi")
      collect_turn(turn_id)
      stop_session(id)

      respond = fn messages ->
        send(test_pid, {:history, messages})
        reply("welcome back")
      end

      assert {:ok, %{id: ^id, cwd: "/tmp/project", model: "stub-model"}} =
               Session.resume(id, session_opts(respond))

      {:ok, turn_id} = Session.send_message(id, "again")
      collect_turn(turn_id)

      assert_receive {:history,
                      [
                        %{role: :user, content: "hi"},
                        %{role: :assistant, content: "hello"},
                        %{role: :user, content: "again"}
                      ]}
    end

    test "returns the info of a session that is already running" do
      id = start_session(fn _ -> reply("hi") end)
      pid = Session.whereis(id)

      assert {:ok, %{id: ^id}} = Session.resume(id, session_opts(fn _ -> reply("x") end))
      assert Session.whereis(id) == pid
    end

    test "an unknown id is :not_found" do
      assert Session.resume("missing", session_opts(fn _ -> reply("x") end)) ==
               {:error, :not_found}
    end
  end

  defp stop_session(id) do
    :ok = DynamicSupervisor.terminate_child(Sadld.SessionSupervisor, Session.whereis(id))
    wait_until(fn -> Session.whereis(id) == nil end, "session #{id} still registered")
  end

  # The registry drops a dead process asynchronously, so poll for changes.
  defp wait_until(check, message, attempts \\ 50) do
    cond do
      check.() ->
        :ok

      attempts == 0 ->
        flunk(message)

      true ->
        Process.sleep(10)
        wait_until(check, message, attempts - 1)
    end
  end

  describe "system prompt" do
    defp start_echo_session(opts) do
      {:ok, id} =
        Session.start(
          Keyword.merge(
            [
              cwd: "/tmp/project",
              model: "stub-model",
              provider: echo_system(),
              tools: {StubTools, run: fn _call, _cwd -> {:ok, "ok"} end}
            ],
            opts
          )
        )

      :ok = SessionEvents.subscribe(id)
      id
    end

    defp provider_system(id) do
      {:ok, turn_id} = Session.send_message(id, "hi")
      [%Notification{method: "turn.delta", params: %{text: text}}, _end] = collect_turn(turn_id)
      text
    end

    # A provider that replies with the system prompt the session gave it.
    defp echo_system do
      {StubProvider,
       respond: fn _messages, on_text, opts ->
         text = Keyword.get(opts, :system, "<none>")
         on_text.(text)
         reply(text)
       end}
    end

    test "is passed to the provider as :system" do
      id = start_echo_session(system_prompt: "Be brief.")

      assert provider_system(id) == "Be brief."
    end

    @tag :tmp_dir
    test "defaults to one built from the cwd's context files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "project rules")

      id = start_echo_session(cwd: tmp_dir)

      system = provider_system(id)
      assert system =~ "Working directory: #{tmp_dir}"
      assert system =~ "project rules"
    end
  end
end
