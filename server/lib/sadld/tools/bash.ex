defmodule Sadld.Tools.Bash do
  @moduledoc """
  The `bash` tool: `bash {command, timeout?}` runs `command` with
  `bash -c` in the session's cwd and returns its combined stdout and
  stderr.

  The command runs through `erlexec` in a process group of its own, and
  the whole group is killed when the command exits, times out, or the
  calling process dies. A cancelled turn therefore leaves no orphans,
  including children the command put in the background.

  A zero exit is `{:ok, output}`. A non-zero exit, a signal or a timeout
  is `{:error, output}` with a note saying which, after the output so far.
  Only the last `:max_output` bytes of output are kept, behind a note
  giving how many were dropped. Invalid UTF-8 is replaced with U+FFFD.

  Options:

    * `:timeout` - seconds a command may run when its call gives no
      `timeout` (default 120)
    * `:max_output` - bytes of output to keep (default 50000)
  """

  @behaviour Sadld.ToolRunner

  @default_timeout 120
  @default_max_output 50_000

  # Seconds between the SIGTERM sent on timeout and the SIGKILL after it.
  @kill_timeout 1

  @impl true
  def run(%{args: args}, cwd, opts) do
    with {:ok, command} <- fetch_command(args),
         {:ok, timeout} <- fetch_timeout(args, opts) do
      max_output = Keyword.get(opts, :max_output, @default_max_output)
      exec(command, cwd, timeout, max_output)
    end
  end

  defp fetch_command(%{"command" => command}) when is_binary(command), do: {:ok, command}
  defp fetch_command(_args), do: {:error, ~s(bash: "command" must be a string)}

  defp fetch_timeout(args, opts) do
    case Map.get(args, "timeout", Keyword.get(opts, :timeout, @default_timeout)) do
      timeout when is_number(timeout) and timeout > 0 -> {:ok, timeout}
      _other -> {:error, ~s(bash: "timeout" must be a positive number of seconds)}
    end
  end

  # erlexec stops a command when the process that started it dies, but only
  # for a linked starter, and that link also delivers the command's exit.
  # So a runner linked to the caller starts the command and traps exits:
  # the caller's death takes the runner and the process group with it.
  defp exec(command, cwd, timeout, max_output) do
    caller = self()
    ref = make_ref()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      send(caller, {ref, run_command(caller, command, cwd, timeout, max_output)})
    end)

    receive do
      {^ref, result} -> result
    end
  end

  defp run_command(caller, command, cwd, timeout, max_output) do
    exec_opts = [
      :link,
      :stdout,
      {:stderr, :stdout},
      {:cd, cwd},
      {:group, 0},
      :kill_group,
      {:kill_timeout, @kill_timeout}
    ]

    {:ok, pid, os_pid} = :exec.run([bash(), "-c", command], exec_opts)
    deadline = System.monotonic_time(:millisecond) + round(timeout * 1000)
    output = %{tail: "", dropped: 0, max: max_output}

    case collect({caller, pid, os_pid}, deadline, output) do
      {output, :normal} -> {:ok, render(output)}
      {output, {:exit_status, status}} -> {:error, annotate(render(output), exit_note(status))}
      {output, :timeout} -> {:error, annotate(render(output), "[timed out after #{timeout}s]")}
    end
  end

  defp bash, do: System.find_executable("bash")

  defp collect({caller, pid, os_pid} = command, deadline, output) do
    receive do
      {:stdout, ^os_pid, data} -> collect(command, deadline, append(output, data))
      {:EXIT, ^pid, reason} -> {output, reason}
      {:EXIT, ^caller, reason} -> exit(reason)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        :exec.stop(os_pid)
        {drain(command, output), :timeout}
    end
  end

  # Collects what a stopped command still writes until it is down.
  defp drain({caller, pid, os_pid} = command, output) do
    receive do
      {:stdout, ^os_pid, data} -> drain(command, append(output, data))
      {:EXIT, ^pid, _reason} -> output
      {:EXIT, ^caller, reason} -> exit(reason)
    end
  end

  defp append(%{tail: tail, dropped: dropped, max: max} = output, data) do
    buffer = tail <> data
    excess = byte_size(buffer) - max

    if excess > 0,
      do: %{output | tail: binary_part(buffer, excess, max), dropped: dropped + excess},
      else: %{output | tail: buffer}
  end

  defp render(%{tail: tail, dropped: 0}), do: String.replace_invalid(tail)

  defp render(%{tail: tail, dropped: dropped}) do
    "[output truncated: #{dropped} bytes omitted]\n" <> String.replace_invalid(tail)
  end

  defp annotate("", note), do: note
  defp annotate(output, note), do: output <> "\n" <> note

  defp exit_note(status) do
    case :exec.status(status) do
      {:status, code} -> "[exit status #{code}]"
      {:signal, signal, _core} -> "[killed by signal #{signal_number(signal)}]"
    end
  end

  defp signal_number(signal) when is_integer(signal), do: signal
  defp signal_number(signal), do: :exec.signal_to_int(signal)
end
