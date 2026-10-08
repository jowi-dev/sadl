defmodule Sadld.Sidecar do
  @moduledoc """
  One opencode plugin running for one worktree in a Bun process: the
  `Sadld.Plugin` behind ADR-0004's sidecar. The process is the host in
  `priv/sidecar/plugin_host.ts`, which sadld talks to over its stdin and
  stdout as `docs/sidecar.md` describes.

  The host runs through erlexec in a process group of its own, linked to
  this server: if the host exits, the server stops with `{:exited,
  reason}` so its supervisor can start a fresh one, and if the server
  dies, the host's group is killed. A normal stop sends the host SIGTERM so
  the plugin can dispose of its resources first.

  The plugin loads in the background. Until it has, `tools/1` waits and
  requests queue in the host. A plugin that fails to load offers no tools,
  leaves hook output unchanged and fails tool calls; the failure is logged
  rather than retried. The plugin's own `client` calls are answered by
  `Sadld.Sidecar.Client`, each in a task under `Sadld.PluginTaskSupervisor`,
  so a call that waits on a session cannot block a hook that session is
  waiting on.

  Options:

    * `:plugin` (required) - path of the plugin module to load
    * `:worktree` (required) - the worktree the plugin serves; the host runs
      there
    * `:name` - the server's name
    * `:bun` - the Bun executable (default `bun` on the `PATH`)
  """

  use GenServer

  require Logger

  alias Sadld.Sidecar.{Client, Protocol}

  @behaviour Sadld.Plugin

  @host Path.join(["sidecar", "plugin_host.ts"])

  # How long to wait for the plugin to load (it may fetch a model) and for
  # a hook to answer before carrying on without the plugin.
  @load_timeout :timer.minutes(2)
  @hook_timeout :timer.minutes(1)

  # Seconds between SIGTERM and SIGKILL when the host is stopped.
  @kill_timeout 5

  @load_failed -32_021
  @internal_error -32_603

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :plugin), Keyword.fetch!(opts, :worktree)},
      start: {__MODULE__, :start_link, [opts]},
      shutdown: :timer.seconds(@kill_timeout * 2)
    }
  end

  @doc "Starts the host and begins loading the plugin. See the module docs."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl Sadld.Plugin
  def tools(server) do
    GenServer.call(server, :tools, @load_timeout)
  catch
    :exit, reason ->
      Logger.warning("plugin tools unavailable: #{inspect(reason)}")
      []
  end

  @impl Sadld.Plugin
  def run_tool(server, call, context) do
    params = %{
      "tool" => call.name,
      "args" => call.args,
      "context" => %{
        "sessionID" => context[:session_id],
        "messageID" => context[:turn_id],
        "callID" => call.id,
        "agent" => "build",
        "directory" => context[:cwd]
      }
    }

    case request(server, "tool.execute", params, :infinity) do
      {:ok, %{"output" => output}} when is_binary(output) -> {:ok, output}
      {:ok, other} -> {:error, "plugin answered #{inspect(other)}"}
      {:error, @load_failed, message} -> {:error, "plugin unavailable: " <> message}
      {:error, _code, message} -> {:error, message}
    end
  end

  @impl Sadld.Plugin
  def hook(server, name, input, output) do
    params = %{"name" => name, "input" => input, "output" => output}

    case request(server, "hook", params, @hook_timeout) do
      {:ok, %{"output" => output}} when is_map(output) ->
        output

      {:ok, _other} ->
        output

      {:error, @load_failed, _message} ->
        output

      {:error, _code, message} ->
        Logger.warning("plugin hook #{name} failed: #{message}")
        output
    end
  end

  @impl Sadld.Plugin
  def event(server, type, properties) do
    GenServer.cast(server, {:event, %{"type" => type, "properties" => properties}})
  end

  @doc "Returns the OS pid of the host."
  @spec os_pid(GenServer.server()) :: non_neg_integer()
  def os_pid(server), do: GenServer.call(server, :os_pid)

  defp request(server, method, params, timeout) do
    GenServer.call(server, {:request, method, params}, timeout)
  catch
    :exit, reason -> {:error, @load_failed, inspect(reason)}
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    plugin = Keyword.fetch!(opts, :plugin)
    worktree = Keyword.fetch!(opts, :worktree)

    with bun when is_binary(bun) <-
           Keyword.get_lazy(opts, :bun, fn -> System.find_executable("bun") end),
         {:ok, pid, os_pid} <- :exec.run([bun, host()], exec_opts(worktree)) do
      state = %{
        plugin: plugin,
        worktree: worktree,
        pid: pid,
        os_pid: os_pid,
        buffer: "",
        next_id: 0,
        pending: %{},
        status: :loading,
        waiting: []
      }

      {:ok, send_request(state, "init", %{"plugin" => plugin, "worktree" => worktree}, :init)}
    else
      nil -> {:stop, :bun_not_found}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp host, do: Path.join(:code.priv_dir(:sadld), @host)

  defp exec_opts(worktree) do
    [
      :link,
      :stdin,
      :stdout,
      :stderr,
      {:cd, worktree},
      {:group, 0},
      :kill_group,
      {:kill_timeout, @kill_timeout}
    ]
  end

  @impl GenServer
  def handle_call(:tools, from, %{status: :loading} = state),
    do: {:noreply, %{state | waiting: [from | state.waiting]}}

  def handle_call(:tools, _from, %{status: {:ready, tools}} = state),
    do: {:reply, tools, state}

  def handle_call(:tools, _from, state), do: {:reply, [], state}

  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  def handle_call({:request, _method, _params}, _from, %{status: {:failed, reason}} = state),
    do: {:reply, {:error, @load_failed, reason}, state}

  def handle_call({:request, "tool.execute", params}, from, state) do
    params = put_in(params, ["context", "worktree"], state.worktree)
    {:noreply, send_request(state, "tool.execute", params, {:call, from})}
  end

  def handle_call({:request, method, params}, from, state),
    do: {:noreply, send_request(state, method, params, {:call, from})}

  @impl GenServer
  def handle_cast({:event, _event}, %{status: {:failed, _reason}} = state), do: {:noreply, state}

  def handle_cast({:event, event}, state) do
    write(state, {:notification, "event", %{"event" => event}})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    [rest | lines] = String.split(state.buffer <> data, "\n") |> Enum.reverse()
    state = Enum.reduce(Enum.reverse(lines), %{state | buffer: rest}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    for line <- String.split(data, "\n", trim: true) do
      Logger.info("[#{Path.basename(state.worktree)} plugin] #{line}")
    end

    {:noreply, state}
  end

  def handle_info({:answer, id, result}, state) do
    write(state, {:response, id, result})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state),
    do: {:stop, {:exited, reason}, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl GenServer
  def terminate({:exited, _reason}, _state), do: :ok

  # Waits for the plugin to dispose of its resources, up to the SIGKILL.
  def terminate(_reason, state) do
    :exec.stop(state.os_pid)

    receive do
      {:EXIT, pid, _reason} when pid == state.pid -> :ok
    after
      :timer.seconds(@kill_timeout + 1) -> :ok
    end
  end

  defp handle_line(line, state) do
    case Protocol.decode(line) do
      {:ok, {:response, id, result}} ->
        {waiter, pending} = Map.pop(state.pending, id)
        respond(waiter, result, %{state | pending: pending})

      {:ok, {:request, id, method, params}} ->
        answer(id, method, params, state)
        state

      _other ->
        Logger.warning("plugin host wrote an unreadable line: #{inspect(line)}")
        state
    end
  end

  defp respond(:init, {:ok, %{"tools" => tools}}, state) do
    tools = for %{"name" => name} = tool <- tools, do: spec(name, tool)
    Enum.each(state.waiting, &GenServer.reply(&1, tools))
    %{state | status: {:ready, tools}, waiting: []}
  end

  defp respond(:init, result, state) do
    reason =
      case result do
        {:error, _code, message} -> message
        {:ok, other} -> "unexpected init result #{inspect(other)}"
      end

    Logger.error("plugin #{state.plugin} failed to load in #{state.worktree}: #{reason}")
    Enum.each(state.waiting, &GenServer.reply(&1, []))
    %{state | status: {:failed, reason}, waiting: []}
  end

  defp respond({:call, from}, result, state) do
    GenServer.reply(from, result)
    state
  end

  defp respond(nil, _result, state), do: state

  defp spec(name, tool) do
    %{
      name: name,
      description: Map.get(tool, "description") || "",
      parameters: Map.get(tool, "parameters") || %{"type" => "object"}
    }
  end

  # Client calls are answered in tasks: see the module docs.
  defp answer(id, method, params, state) do
    server = self()
    worktree = state.worktree

    Task.Supervisor.start_child(Sadld.PluginTaskSupervisor, fn ->
      result =
        try do
          Client.handle(method, params, worktree)
        rescue
          error -> {:error, @internal_error, Exception.message(error)}
        end

      send(server, {:answer, id, result})
    end)
  end

  defp send_request(state, method, params, waiter) do
    id = state.next_id
    write(state, {:request, id, method, params})
    %{state | next_id: id + 1, pending: Map.put(state.pending, id, waiter)}
  end

  defp write(state, message), do: :exec.send(state.os_pid, Protocol.encode(message) <> "\n")
end
