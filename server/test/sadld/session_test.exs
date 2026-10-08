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
    ] ++ Keyword.take(opts, [:permissions])
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

  describe "permissions" do
    @bash %{id: "call_1", name: "bash", args: %{"command" => "rm -rf build"}}

    # A model that calls bash once, then replies with the result it read.
    defp call_bash_once(messages) do
      case List.last(messages) do
        %{role: :user} -> {:ok, %{text: "", tool_calls: [@bash], usage: @usage}}
        %{role: :tool, content: content} -> reply("saw: " <> content)
      end
    end

    defp policy(action) do
      {:ok, policy} =
        Sadld.Permissions.parse(%{
          "default" => "allow",
          "rules" => [%{"tool" => "bash", "action" => action}]
        })

      policy
    end

    # Starts a session whose tools report each run to the test process.
    defp start_with_policy(action) do
      test_pid = self()

      run = fn call, _cwd ->
        send(test_pid, {:ran, call.id})
        {:ok, "removed"}
      end

      start_session(&call_bash_once/1, run: run, permissions: policy(action))
    end

    defp assert_waiting(turn_id) do
      assert_receive {:session_event, _id, %Notification{method: "tool.call"}}
      assert_receive {:session_event, _id, %Notification{method: "permission.request"} = n}
      assert n.params.turn_id == turn_id
      n.params
    end

    test "a call the policy denies fails without running and the turn continues" do
      id = start_with_policy("deny")
      {:ok, turn_id} = Session.send_message(id, "clean")

      assert [
               %Notification{method: "tool.call"},
               %Notification{method: "tool.result", params: result},
               %Notification{method: "turn.delta"},
               %Notification{method: "turn.end", params: %{stop_reason: "completed"}}
             ] = collect_turn(turn_id)

      assert result.is_error
      assert result.output == "permission denied by policy"
      refute_received {:ran, _call_id}
    end

    test "a call the policy asks about waits for a client to allow it" do
      id = start_with_policy("ask")
      {:ok, turn_id} = Session.send_message(id, "clean")

      assert assert_waiting(turn_id) == %{session_id: id, turn_id: turn_id, call_id: "call_1"}
      refute_receive {:ran, _call_id}, 50

      assert Session.permit(id, "call_1", :allow) == :ok

      assert_receive {:ran, "call_1"}

      assert [
               %Notification{method: "tool.result", params: %{output: "removed"}},
               %Notification{method: "turn.delta", params: %{text: "saw: removed"}},
               %Notification{method: "turn.end", params: %{stop_reason: "completed"}}
             ] = collect_turn(turn_id)
    end

    test "a call a client denies fails without running" do
      id = start_with_policy("ask")
      {:ok, turn_id} = Session.send_message(id, "clean")
      assert_waiting(turn_id)

      assert Session.permit(id, "call_1", :deny) == :ok

      assert [
               %Notification{method: "tool.result", params: result},
               %Notification{method: "turn.delta"},
               %Notification{method: "turn.end", params: %{stop_reason: "completed"}}
             ] = collect_turn(turn_id)

      assert result == %{
               session_id: id,
               turn_id: turn_id,
               call_id: "call_1",
               output: "permission denied by the user",
               is_error: true
             }

      refute_received {:ran, _call_id}
    end

    test "only the first answer counts" do
      id = start_with_policy("ask")
      {:ok, turn_id} = Session.send_message(id, "clean")
      assert_waiting(turn_id)

      assert Session.permit(id, "call_1", :allow) == :ok
      assert Session.permit(id, "call_1", :deny) == {:error, :not_pending}
      assert List.last(collect_turn(turn_id)).params.stop_reason == "completed"
    end

    test "answering a call that is not waiting is :not_pending" do
      id = start_with_policy("ask")
      assert Session.permit(id, "call_1", :allow) == {:error, :not_pending}

      {:ok, turn_id} = Session.send_message(id, "clean")
      assert_waiting(turn_id)
      assert Session.permit(id, "other", :allow) == {:error, :not_pending}
    end

    test "cancelling a waiting turn drops its request" do
      id = start_with_policy("ask")
      {:ok, turn_id} = Session.send_message(id, "clean")
      assert_waiting(turn_id)

      assert Session.cancel(id) == :ok

      assert [%Notification{method: "turn.end", params: %{stop_reason: "cancelled"}}] =
               collect_turn(turn_id)

      assert Session.permit(id, "call_1", :allow) == {:error, :not_pending}
      refute_received {:ran, _call_id}
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
    assert Session.permit("missing", "call_1", :allow) == {:error, :not_found}
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

  describe "compaction" do
    # A small window: compaction is needed once the context passes 80 tokens.
    @small_window [context_window: 100, reserve_tokens: 20, keep_recent_tokens: 1]

    # Answers summary requests with `summary` and everything else with
    # `reply`, telling the test what each request held.
    defp compacting_provider(summary, reply_usage) do
      test_pid = self()

      {StubProvider,
       respond: fn messages, on_text, opts ->
         if opts[:system] =~ "summarization" do
           send(test_pid, {:summarize, messages})
           summary.()
         else
           send(test_pid, {:chat, messages})
           on_text.("ok")
           {:ok, %{text: "ok", tool_calls: [], usage: reply_usage}}
         end
       end}
    end

    defp summary(text), do: fn -> {:ok, %{text: text, tool_calls: [], usage: @usage}} end

    defp start_compacting_session(provider, compaction) do
      {:ok, id} =
        Session.start(
          cwd: "/tmp/project",
          model: "stub-model",
          system_prompt: "sys",
          provider: provider,
          tools: {StubTools, run: fn _call, _cwd -> {:ok, "ok"} end},
          compaction: compaction
        )

      :ok = SessionEvents.subscribe(id)
      id
    end

    defp turn(id, text) do
      {:ok, turn_id} = Session.send_message(id, text)
      {turn_id, collect_turn(turn_id)}
    end

    test "a turn nearing the context limit summarizes older messages first" do
      provider = compacting_provider(summary("S"), %{input_tokens: 90, output_tokens: 5})
      id = start_compacting_session(provider, @small_window)

      turn(id, "first")
      assert_receive {:chat, [%{content: "first"}]}
      refute_received {:summarize, _}

      {turn_id, notifications} = turn(id, "second")

      assert_receive {:summarize, [%{role: :user, content: prompt}]}
      assert prompt =~ "first"
      refute prompt =~ "second"

      assert_receive {:chat, [%{role: :user, content: summary}, %{content: "second"}]}
      assert summary =~ "S"

      assert [
               %Notification{method: "turn.compacted", params: compacted},
               %Notification{method: "turn.delta"},
               %Notification{method: "turn.end", params: %{usage: usage}}
             ] = notifications

      assert compacted == %{session_id: id, turn_id: turn_id, summary: "S"}
      assert usage == %{input_tokens: 93, output_tokens: 7}

      assert length(Session.messages(id)) == 4
      assert Store.messages(id) == Session.messages(id)
      assert Store.latest_compaction(id) == %{summary: "S", first_kept: 2}
    end

    test "a context within the limit is sent whole" do
      provider = compacting_provider(summary("S"), @usage)
      id = start_compacting_session(provider, [])

      turn(id, "first")
      turn(id, "second")

      assert_receive {:chat, [_, _, %{content: "second"}]}
      refute_received {:summarize, _}
    end

    test "a failed summary fails the turn" do
      provider =
        compacting_provider(fn -> {:error, :boom} end, %{input_tokens: 90, output_tokens: 5})

      id = start_compacting_session(provider, @small_window)
      turn(id, "first")

      {_turn_id, notifications} = turn(id, "second")

      assert [
               %Notification{method: "error"},
               %Notification{method: "turn.end", params: %{stop_reason: "error"}}
             ] = notifications

      assert Store.latest_compaction(id) == nil
    end

    test "a resumed session sends the compacted context" do
      provider = compacting_provider(summary("S"), %{input_tokens: 90, output_tokens: 5})
      id = start_compacting_session(provider, @small_window)
      turn(id, "first")
      turn(id, "second")
      stop_session(id)

      provider = compacting_provider(summary("S2"), @usage)
      {:ok, _info} = Session.resume(id, provider: provider, tools: {StubTools, run: nil})
      turn(id, "third")

      assert_receive {:chat,
                      [%{content: summary}, %{content: "second"}, _ok, %{content: "third"}]}

      assert summary =~ "S"
    end

    test "compact summarizes the conversation now, as a turn of its own" do
      provider = compacting_provider(summary("all of it"), @usage)
      id = start_compacting_session(provider, [])
      turn(id, "first")

      assert {:ok, turn_id} = Session.compact(id)

      assert [
               %Notification{method: "turn.compacted", params: %{summary: "all of it"}},
               %Notification{method: "turn.end", params: turn_end}
             ] = collect_turn(turn_id)

      assert turn_end.stop_reason == "completed"
      assert turn_end.usage == @usage
      assert Store.latest_compaction(id) == %{summary: "all of it", first_kept: 2}

      turn(id, "next")
      assert_receive {:chat, [%{content: summary}, %{content: "next"}]}
      assert summary =~ "all of it"
    end

    test "compact with nothing new to summarize just ends the turn" do
      provider = compacting_provider(summary("S"), @usage)
      id = start_compacting_session(provider, [])

      {:ok, turn_id} = Session.compact(id)

      assert [%Notification{method: "turn.end", params: %{stop_reason: "completed"}}] =
               collect_turn(turn_id)

      refute_received {:summarize, _}
    end

    test "compact is refused while a turn runs, and on an unknown session" do
      test_pid = self()

      provider =
        {StubProvider,
         respond: fn _messages ->
           send(test_pid, :called)

           receive do
             :release -> reply("late")
           end
         end}

      id = start_compacting_session(provider, [])
      {:ok, _turn_id} = Session.send_message(id, "hi")
      assert_receive :called

      assert Session.compact(id) == {:error, :busy}
      assert Session.compact("missing") == {:error, :not_found}
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
