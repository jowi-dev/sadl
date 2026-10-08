defmodule Sadld.Session do
  @moduledoc """
  One conversation. Each session is a process under
  `Sadld.SessionSupervisor`, registered in `Sadld.SessionRegistry` by an id
  minted at `start/1`, so a crash in one session leaves the others alone.

  The session owns the message list and runs turns. A turn sends the
  conversation to the provider, streams the reply text, runs any tool calls
  and feeds their results back, repeating until a reply has no tool calls.
  The loop runs in a task under `Sadld.TurnSupervisor` so the session keeps
  answering calls, and `cancel/1` can kill it mid-turn.

  Progress is broadcast on the session's `Sadld.SessionEvents` topic, so
  every subscriber receives
  `{:session_event, session_id, %Sadld.Protocol.Notification{}}` messages:
  the `turn.delta`, `tool.call`, `permission.request`, `tool.result`,
  `turn.compacted`, `turn.end` and `error` notifications of
  `docs/protocol.md`, in order. All of them are sent by the session
  process, so a subscriber that also made the `send_message/2` call gets the
  reply before the turn's first notification.

  Each tool call is checked against the session's `Sadld.Permissions`
  policy before it runs. A denied call fails with an error result the model
  reads. A call the policy asks about is broadcast as `permission.request`
  and waits, with the rest of the turn, until `permit/3` answers it or the
  turn is cancelled.

  Before each request to the provider, a turn checks whether the context
  is near the model's limit and, if so, compacts it with
  `Sadld.Compaction` first. `compact/1` does the same on demand. A
  compaction changes only what is sent: the message list and the store keep
  every message, and the latest compaction is stored beside them and
  reloaded when the session starts. The context's size is the provider's
  reported usage for the last request plus an estimate of the messages
  since, or an estimate of the whole context when there is no report yet.

  A turn appends to the message list only at consistent points: the user
  message when it starts, then each assistant reply together with the
  results of its tool calls. A cancelled or failed turn keeps the steps it
  finished.

  Every append is written to `Sadld.Store` first, and the user message is
  stored before `send_message/2` replies. A session process rebuilds its
  message list from the store when it starts, so one the supervisor
  restarts after a crash, or one brought back by `resume/2`, carries on
  where it left off. A turn that was running when the process died is lost.
  """

  use GenServer, restart: :transient

  alias Sadld.Protocol.Notification
  alias Sadld.{Compaction, Permissions, SessionEvents, Store}

  @registry Sadld.SessionRegistry
  @supervisor Sadld.SessionSupervisor
  @task_supervisor Sadld.TurnSupervisor

  # JSON-RPC "Internal error" (docs/protocol.md), for failures mid-turn.
  @internal_error -32_603

  @zero_usage %{input_tokens: 0, output_tokens: 0}

  @type id :: String.t()

  @type info :: %{id: id(), cwd: Path.t(), model: String.t(), updated_at: DateTime.t()}

  @doc """
  Records a new session in `Sadld.Store`, starts it under
  `Sadld.SessionSupervisor` and returns its id.

  Options:

    * `:cwd` (required) - directory the session's tools run in
    * `:model` (required) - model name, passed to the provider as `:model`
    * `:provider` (required) - `{module, opts}` for a `Sadld.Provider`
    * `:tools` (required) - `{module, opts}` for a `Sadld.ToolRunner`
    * `:permissions` - the `Sadld.Permissions` policy that decides which tool
      calls run (default `Sadld.Permissions.allow_all/0`)
    * `:system_prompt` - system prompt passed to the provider as `:system`
      (default `Sadld.SystemPrompt.build/1` of `:cwd`, built once at start
      so later edits to context files reach only new sessions)
    * `:compaction` - options for `Sadld.Compaction`, over its app config
  """
  @spec start(keyword()) :: {:ok, id()} | {:error, term()}
  def start(opts) do
    id = new_id()
    session = %{id: id, cwd: Keyword.fetch!(opts, :cwd), model: Keyword.fetch!(opts, :model)}
    {:ok, _info} = Store.create_session(session)

    case start_child(Keyword.put(opts, :id, id)) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Brings back the stored session `id` and returns its info. A session that
  is not running is started with its stored `:cwd` and `:model` and its
  stored messages; one already running is left as it is.

  Takes the `:provider`, `:tools`, `:permissions` and `:compaction` options
  of `start/1`.
  """
  @spec resume(id(), keyword()) :: {:ok, Store.session_info()} | {:error, :not_found | term()}
  def resume(id, opts) do
    with {:ok, info} <- Store.fetch_session(id) do
      case start_child(Keyword.merge(opts, id: id, cwd: info.cwd, model: info.model)) do
        {:ok, _pid} -> {:ok, info}
        {:error, {:already_started, _pid}} -> {:ok, info}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Returns every stored session, most recently updated first."
  @spec list() :: [Store.session_info()]
  def list, do: Store.list_sessions()

  defp start_child(opts), do: DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts})

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  @doc "Returns the pid of session `id`, or `nil` if none is running."
  @spec whereis(id()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Starts a turn with the user's `text` and returns its turn id. Fails with
  `:busy` while another turn is running.
  """
  @spec send_message(id(), String.t()) :: {:ok, String.t()} | {:error, :busy | :not_found}
  def send_message(id, text), do: call(id, {:send_message, text})

  @doc """
  Stops the running turn, which then ends with `stop_reason` `"cancelled"`.
  Does nothing when no turn is running.
  """
  @spec cancel(id()) :: :ok | {:error, :not_found}
  def cancel(id), do: call(id, :cancel)

  @doc """
  Answers the permission request for tool call `call_id`: `:allow` runs
  the tool, `:deny` fails it without running. Fails with `:not_pending`
  when that call is not waiting for an answer, which includes one already
  answered.
  """
  @spec permit(id(), String.t(), :allow | :deny) :: :ok | {:error, :not_pending | :not_found}
  def permit(id, call_id, decision) when decision in [:allow, :deny],
    do: call(id, {:permit, call_id, decision})

  @doc """
  Starts a turn that compacts the session's context now and returns its
  turn id. It summarizes everything but the recent tail, or the whole
  conversation when the tail is all there is; with nothing new to
  summarize it just ends. Fails with `:busy` while another turn is running.
  """
  @spec compact(id()) :: {:ok, String.t()} | {:error, :busy | :not_found}
  def compact(id), do: call(id, :compact)

  @doc "Returns the session's message list, oldest first."
  @spec messages(id()) :: [Sadld.Provider.message()] | {:error, :not_found}
  def messages(id), do: call(id, :messages)

  @doc """
  Describes the session: its `id`, `cwd` and `model`, and `updated_at`, the
  UTC time its message list last changed (or it started).
  """
  @spec info(id()) :: info() | {:error, :not_found}
  def info(id), do: call(id, :info)

  defp call(id, request) do
    GenServer.call(via(id), request)
  catch
    :exit, {:noproc, _call} -> {:error, :not_found}
  end

  defp via(id), do: {:via, Registry, {@registry, id}}

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @impl true
  def init(opts) do
    {provider, provider_opts} = Keyword.fetch!(opts, :provider)
    id = Keyword.fetch!(opts, :id)
    model = Keyword.fetch!(opts, :model)
    cwd = Keyword.fetch!(opts, :cwd)

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn -> Sadld.SystemPrompt.build(cwd) end)

    provider_opts =
      provider_opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:system, system_prompt)

    state = %{
      id: id,
      cwd: cwd,
      model: model,
      provider: {provider, provider_opts},
      tools: Keyword.fetch!(opts, :tools),
      permissions: Keyword.get_lazy(opts, :permissions, &Permissions.allow_all/0),
      compaction_opts: Keyword.get(opts, :compaction, []),
      messages: Store.messages(id),
      compaction: Store.latest_compaction(id),
      context_tokens: nil,
      updated_at: now(),
      turn: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, _text}, _from, %{turn: turn} = state) when turn != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:compact, _from, %{turn: turn} = state) when turn != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, text}, _from, state) do
    turn_id = new_id()
    state = append_messages(state, [%{role: :user, content: text}])
    {:reply, {:ok, turn_id}, state, {:continue, {:start_turn, turn_id, :chat}}}
  end

  def handle_call(:compact, _from, state) do
    turn_id = new_id()
    {:reply, {:ok, turn_id}, state, {:continue, {:start_turn, turn_id, :compact}}}
  end

  def handle_call(:cancel, _from, %{turn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, %{turn: turn} = state) do
    Task.shutdown(turn.task, :brutal_kill)
    {:reply, :ok, end_turn(state, "cancelled")}
  end

  def handle_call({:permit, call_id, decision}, _from, %{turn: turn} = state) do
    if turn != nil and MapSet.member?(turn.asks, call_id) do
      send(turn.task.pid, {:permit, call_id, decision})
      {:reply, :ok, %{state | turn: %{turn | asks: MapSet.delete(turn.asks, call_id)}}}
    else
      {:reply, {:error, :not_pending}, state}
    end
  end

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:id, :cwd, :model, :updated_at]), state}
  end

  @impl true
  def handle_continue({:start_turn, turn_id, job}, state) do
    session = self()
    ctx = Map.take(state, [:messages, :compaction, :context_tokens])

    env = %{
      cwd: state.cwd,
      provider: state.provider,
      tools: state.tools,
      permissions: state.permissions,
      compaction: state.compaction_opts
    }

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        report = &send(session, {:turn, turn_id, &1})

        case job do
          :chat -> run_turn(ctx, env, report)
          :compact -> run_compact(ctx, env, report)
        end
      end)

    turn = %{id: turn_id, task: task, usage: @zero_usage, asks: MapSet.new()}
    {:noreply, %{state | turn: turn}}
  end

  @impl true
  def handle_info({:turn, turn_id, event}, %{turn: %{id: turn_id}} = state) do
    {:noreply, handle_turn_event(event, state)}
  end

  # Stragglers from a cancelled turn.
  def handle_info({:turn, _turn_id, _event}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{turn: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      :completed -> {:noreply, end_turn(state, "completed")}
      {:error, reason} -> {:noreply, fail_turn(state, reason)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{turn: %{task: %Task{ref: ref}}} = state) do
    {:noreply, fail_turn(state, reason)}
  end

  defp handle_turn_event({:notify, method, params}, state) do
    notify(state, method, Map.put(params, :turn_id, state.turn.id))
    state
  end

  defp handle_turn_event({:ask, call_id}, %{turn: turn} = state) do
    state = %{state | turn: %{turn | asks: MapSet.put(turn.asks, call_id)}}
    notify(state, "permission.request", %{turn_id: turn.id, call_id: call_id})
    state
  end

  defp handle_turn_event({:step, messages, usage}, state) do
    turn = %{state.turn | usage: add_usage(state.turn.usage, usage)}
    :ok = Store.append_messages(state.id, messages)
    %{add_step(state, messages, usage) | turn: turn, updated_at: now()}
  end

  defp handle_turn_event({:compacted, compaction, usage}, state) do
    :ok = Store.add_compaction(state.id, compaction)
    notify(state, "turn.compacted", %{turn_id: state.turn.id, summary: compaction.summary})
    turn = %{state.turn | usage: add_usage(state.turn.usage, usage)}
    %{state | compaction: compaction, context_tokens: nil, turn: turn}
  end

  defp append_messages(state, messages) do
    :ok = Store.append_messages(state.id, messages)
    %{state | messages: state.messages ++ messages, updated_at: now()}
  end

  defp now, do: DateTime.utc_now(:second)

  defp fail_turn(state, reason) do
    notify(state, "error", %{code: @internal_error, message: inspect(reason)})
    end_turn(state, "error")
  end

  defp end_turn(%{turn: turn} = state, stop_reason) do
    notify(state, "turn.end", %{turn_id: turn.id, stop_reason: stop_reason, usage: turn.usage})
    %{state | turn: nil}
  end

  defp notify(state, method, params) do
    params = Map.put(params, :session_id, state.id)
    SessionEvents.broadcast(state.id, %Notification{method: method, params: params})
  end

  defp add_usage(a, b) do
    %{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens
    }
  end

  # Adds a step's messages to `ctx` (the session state, or the turn task's
  # copy of it). The provider's usage for the step's request, plus its reply,
  # is the size of the context up to and including the reply; the tool
  # results after it are estimated when the size is next needed.
  defp add_step(ctx, step, usage) do
    context_tokens =
      if usage.input_tokens > 0,
        do: %{tokens: usage.input_tokens + usage.output_tokens, at: length(ctx.messages) + 1},
        else: nil

    %{ctx | messages: ctx.messages ++ step, context_tokens: context_tokens}
  end

  # The tokens the next request would send: the last reported size plus an
  # estimate of what came after it, or an estimate of the whole context when
  # there is no reported size since the session started or last compacted.
  defp context_size(%{context_tokens: %{tokens: tokens, at: at}} = ctx, _env),
    do: tokens + Compaction.estimate_tokens(Enum.drop(ctx.messages, at))

  defp context_size(ctx, %{provider: {_provider, provider_opts}}) do
    system = Keyword.get(provider_opts, :system) || ""
    context = Compaction.context(ctx.messages, ctx.compaction)
    Compaction.estimate_tokens(system) + Compaction.estimate_tokens(context)
  end

  # The turn loop, run inside the turn task. `report` sends an event to the
  # session. Before each request it compacts the context if that is near
  # the limit. Returns `:completed` or `{:error, reason}`.
  defp run_turn(ctx, env, report) do
    with {:ok, ctx} <- maybe_compact(ctx, env, report),
         {:ok, reply} <- request(ctx, env, report) do
      %{text: text, tool_calls: tool_calls, usage: usage} = reply
      results = Enum.map(tool_calls, &run_tool(&1, Map.put(env, :report, report)))
      step = [%{role: :assistant, content: text, tool_calls: tool_calls} | results]
      report.({:step, step, usage})

      if tool_calls == [],
        do: :completed,
        else: run_turn(add_step(ctx, step, usage), env, report)
    end
  end

  defp request(ctx, %{provider: {provider, provider_opts}}, report) do
    on_text = &report.({:notify, "turn.delta", %{text: &1}})
    messages = Compaction.context(ctx.messages, ctx.compaction)
    provider.chat(messages, Keyword.put(provider_opts, :on_text, on_text))
  end

  # A `compact/1` turn: summarizes everything but the recent tail, or the
  # whole conversation when the tail is all there is.
  defp run_compact(ctx, env, report) do
    with {:ok, _ctx} <- compact(ctx, env, report, [force: true] ++ env.compaction),
         do: :completed
  end

  defp maybe_compact(ctx, env, report) do
    if Compaction.needed?(context_size(ctx, env), env.compaction),
      do: compact(ctx, env, report, env.compaction),
      else: {:ok, ctx}
  end

  defp compact(ctx, env, report, opts) do
    case Compaction.compact(ctx.messages, ctx.compaction, env.provider, opts) do
      {:ok, compaction, usage} ->
        report.({:compacted, compaction, usage})
        {:ok, %{ctx | compaction: compaction, context_tokens: nil}}

      :noop ->
        {:ok, ctx}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_tool(call, %{tools: {tools, tools_opts}, report: report} = context) do
    report.({:notify, "tool.call", %{call_id: call.id, name: call.name, args: call.args}})

    result =
      case permission(call, context) do
        :allow -> tools.run(call, context.cwd, tools_opts)
        {:deny, by} -> {:error, "permission denied by " <> by}
      end

    {output, is_error} =
      case result do
        {:ok, output} -> {output, false}
        {:error, output} -> {output, true}
      end

    report.({:notify, "tool.result", %{call_id: call.id, output: output, is_error: is_error}})
    %{role: :tool, call_id: call.id, content: output, is_error: is_error}
  end

  # Asking reports the call to the session, which broadcasts the request
  # and forwards the first client's answer here.
  defp permission(%{id: call_id} = call, %{permissions: permissions, report: report}) do
    case Permissions.check(permissions, call) do
      :allow ->
        :allow

      :deny ->
        {:deny, "policy"}

      :ask ->
        report.({:ask, call_id})

        receive do
          {:permit, ^call_id, :allow} -> :allow
          {:permit, ^call_id, :deny} -> {:deny, "the user"}
        end
    end
  end
end
