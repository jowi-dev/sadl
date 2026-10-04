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

  Progress reaches the session's `:listener` as
  `{:session_event, session_id, %Sadld.Protocol.Notification{}}` messages:
  the `turn.delta`, `tool.call`, `tool.result`, `turn.end` and `error`
  notifications of `docs/protocol.md`, in order. All of them are sent by
  the session process, so a listener that also made the `send_message/2`
  call gets the reply before the turn's first notification.

  A turn appends to the message list only at consistent points: the user
  message when it starts, then each assistant reply together with the
  results of its tool calls. A cancelled or failed turn keeps the steps it
  finished.
  """

  use GenServer, restart: :transient

  alias Sadld.Protocol.Notification

  @registry Sadld.SessionRegistry
  @supervisor Sadld.SessionSupervisor
  @task_supervisor Sadld.TurnSupervisor

  # JSON-RPC "Internal error" (docs/protocol.md), for failures mid-turn.
  @internal_error -32_603

  @zero_usage %{input_tokens: 0, output_tokens: 0}

  @type id :: String.t()

  @doc """
  Starts a session under `Sadld.SessionSupervisor` and returns its id.

  Options:

    * `:cwd` (required) - directory the session's tools run in
    * `:model` (required) - model name, passed to the provider as `:model`
    * `:provider` (required) - `{module, opts}` for a `Sadld.Provider`
    * `:tools` (required) - `{module, opts}` for a `Sadld.ToolRunner`
    * `:listener` - pid that receives the session's notifications
  """
  @spec start(keyword()) :: {:ok, id()} | {:error, term()}
  def start(opts) do
    id = new_id()

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, Keyword.put(opts, :id, id)}) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

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

    state = %{
      id: Keyword.fetch!(opts, :id),
      cwd: Keyword.fetch!(opts, :cwd),
      provider: {provider, Keyword.put(provider_opts, :model, Keyword.fetch!(opts, :model))},
      tools: Keyword.fetch!(opts, :tools),
      listener: Keyword.get(opts, :listener),
      messages: [],
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
    state = %{state | messages: state.messages ++ [%{role: :user, content: text}]}
    {:reply, {:ok, turn_id}, state, {:continue, {:start_turn, turn_id}}}
  end

  def handle_call(:cancel, _from, %{turn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, %{turn: turn} = state) do
    Task.shutdown(turn.task, :brutal_kill)
    {:reply, :ok, end_turn(state, "cancelled")}
  end

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

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
    %{state | messages: state.messages ++ messages, turn: turn}
  end

  defp fail_turn(state, reason) do
    notify(state, "error", %{code: @internal_error, message: inspect(reason)})
    end_turn(state, "error")
  end

  defp end_turn(%{turn: turn} = state, stop_reason) do
    notify(state, "turn.end", %{turn_id: turn.id, stop_reason: stop_reason, usage: turn.usage})
    %{state | turn: nil}
  end

  defp notify(%{listener: nil}, _method, _params), do: :ok

  defp notify(state, method, params) do
    params = Map.put(params, :session_id, state.id)

    send(
      state.listener,
      {:session_event, state.id, %Notification{method: method, params: params}}
    )
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
