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
  the `turn.delta`, `tool.call`, `tool.result`, `turn.end` and `error`
  notifications of `docs/protocol.md`, in order. All of them are sent by
  the session process, so a subscriber that also made the `send_message/2`
  call gets the reply before the turn's first notification.

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
  alias Sadld.{SessionEvents, Store}

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
    * `:system_prompt` - system prompt passed to the provider as `:system`
      (default `Sadld.SystemPrompt.build/1` of `:cwd`, built once at start
      so later edits to context files reach only new sessions)
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

  Takes the `:provider` and `:tools` options of `start/1`.
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
      messages: Store.messages(id),
      updated_at: now(),
      turn: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, _text}, _from, %{turn: turn} = state) when turn != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, text}, _from, state) do
    turn_id = new_id()
    state = append_messages(state, [%{role: :user, content: text}])
    {:reply, {:ok, turn_id}, state, {:continue, {:start_turn, turn_id}}}
  end

  def handle_call(:cancel, _from, %{turn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, %{turn: turn} = state) do
    Task.shutdown(turn.task, :brutal_kill)
    {:reply, :ok, end_turn(state, "cancelled")}
  end

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:id, :cwd, :model, :updated_at]), state}
  end

  @impl true
  def handle_continue({:start_turn, turn_id}, state) do
    session = self()
    %{cwd: cwd, provider: provider, tools: tools, messages: messages} = state

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        report = &send(session, {:turn, turn_id, &1})
        run_turn(messages, provider, tools, cwd, report)
      end)

    {:noreply, %{state | turn: %{id: turn_id, task: task, usage: @zero_usage}}}
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

  defp handle_turn_event({:step, messages, usage}, state) do
    turn = %{state.turn | usage: add_usage(state.turn.usage, usage)}
    %{append_messages(state, messages) | turn: turn}
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

  # The turn loop, run inside the turn task. `report` sends an event to the
  # session. Returns `:completed` or `{:error, reason}`.
  defp run_turn(messages, {provider, provider_opts} = p, tools, cwd, report) do
    on_text = &report.({:notify, "turn.delta", %{text: &1}})

    case provider.chat(messages, Keyword.put(provider_opts, :on_text, on_text)) do
      {:ok, %{text: text, tool_calls: tool_calls, usage: usage}} ->
        results = Enum.map(tool_calls, &run_tool(&1, tools, cwd, report))
        step = [%{role: :assistant, content: text, tool_calls: tool_calls} | results]
        report.({:step, step, usage})

        if tool_calls == [],
          do: :completed,
          else: run_turn(messages ++ step, p, tools, cwd, report)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_tool(call, {tools, tools_opts}, cwd, report) do
    report.({:notify, "tool.call", %{call_id: call.id, name: call.name, args: call.args}})

    {output, is_error} =
      case tools.run(call, cwd, tools_opts) do
        {:ok, output} -> {output, false}
        {:error, output} -> {output, true}
      end

    report.({:notify, "tool.result", %{call_id: call.id, output: output, is_error: is_error}})
    %{role: :tool, call_id: call.id, content: output, is_error: is_error}
  end
end
