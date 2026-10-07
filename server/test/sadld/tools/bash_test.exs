defmodule Sadld.Tools.BashTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol.Notification
  alias Sadld.{Session, SessionEvents}
  alias Sadld.Test.StubProvider
  alias Sadld.Tools.Bash

  setup do
    dir = Path.join(System.tmp_dir!(), "sadld-bash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Starts `sleep 100` in the background, records its OS pid in `pid`, and
  # waits on it, so the command only ends when the sleep does.
  @orphan_maker "sleep 100 & echo $! > pid; wait"

  defp run(args, cwd, opts \\ []) do
    Bash.run(%{id: "call_1", name: "bash", args: args}, cwd, opts)
  end

  defp read_pid(dir) do
    path = Path.join(dir, "pid")

    wait_until(fn ->
      case File.read(path) do
        {:ok, contents} -> String.ends_with?(contents, "\n")
        {:error, _} -> false
      end
    end)

    path |> File.read!() |> String.trim()
  end

  defp alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      # A zombie has exited; it only waits to be reaped.
      {:ok, stat} -> not String.contains?(stat, ") Z ")
      {:error, _} -> false
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  test "runs the command in the session's cwd", %{dir: dir} do
    assert run(%{"command" => "pwd"}, dir) == {:ok, dir <> "\n"}
  end

  test "captures stdout and stderr together, in order", %{dir: dir} do
    assert run(%{"command" => "echo out; echo err >&2; echo again"}, dir) ==
             {:ok, "out\nerr\nagain\n"}
  end

  test "a non-zero exit is an error that reports the status", %{dir: dir} do
    assert run(%{"command" => "echo failing; exit 3"}, dir) ==
             {:error, "failing\n\n[exit status 3]"}
  end

  test "a command killed by a signal reports the signal", %{dir: dir} do
    assert {:error, output} = run(%{"command" => "kill -TERM $$"}, dir)
    assert output =~ "[killed by signal 15]"
  end

  test "a timeout kills the command and returns its output so far", %{dir: dir} do
    assert {:error, output} = run(%{"command" => "echo start; sleep 10", "timeout" => 0.2}, dir)
    assert output == "start\n\n[timed out after 0.2s]"
  end

  test "a timeout kills the whole process group", %{dir: dir} do
    assert {:error, _output} = run(%{"command" => @orphan_maker, "timeout" => 0.5}, dir)

    os_pid = read_pid(dir)
    wait_until(fn -> not alive?(os_pid) end)
  end

  test "the default timeout comes from the options", %{dir: dir} do
    assert {:error, output} = run(%{"command" => "sleep 10"}, dir, timeout: 0.1)
    assert output =~ "[timed out after 0.1s]"
  end

  test "output past the cap keeps the tail and says what it dropped", %{dir: dir} do
    command = "printf 'head'; head -c 1000 /dev/zero | tr '\\0' a; printf 'tail'"

    assert {:ok, output} = run(%{"command" => command}, dir, max_output: 100)

    assert output ==
             "[output truncated: 908 bytes omitted]\n" <> String.duplicate("a", 96) <> "tail"
  end

  test "invalid UTF-8 in the output is replaced", %{dir: dir} do
    assert run(%{"command" => "printf 'a\\377b'"}, dir) == {:ok, "a�b"}
  end

  test "rejects a missing or non-string command", %{dir: dir} do
    assert run(%{}, dir) == {:error, "bash: \"command\" must be a string"}
    assert run(%{"command" => 1}, dir) == {:error, "bash: \"command\" must be a string"}
  end

  test "rejects a timeout that is not a positive number", %{dir: dir} do
    for timeout <- [0, -1, "5"] do
      assert run(%{"command" => "true", "timeout" => timeout}, dir) ==
               {:error, "bash: \"timeout\" must be a positive number of seconds"}
    end
  end

  test "cancelling the session's turn kills the whole process group", %{dir: dir} do
    call = %{id: "call_1", name: "bash", args: %{"command" => @orphan_maker}}

    respond = fn _messages ->
      {:ok, %{text: "", tool_calls: [call], usage: %{input_tokens: 0, output_tokens: 0}}}
    end

    {:ok, id} =
      Session.start(
        cwd: dir,
        model: "stub-model",
        provider: {StubProvider, respond: respond},
        tools: {Bash, []}
      )

    :ok = SessionEvents.subscribe(id)
    {:ok, turn_id} = Session.send_message(id, "go")
    assert_receive {:session_event, ^id, %Notification{method: "tool.call"}}
    os_pid = read_pid(dir)
    assert alive?(os_pid)

    assert Session.cancel(id) == :ok

    assert_receive {:session_event, ^id,
                    %Notification{method: "turn.end", params: %{turn_id: ^turn_id}}}

    wait_until(fn -> not alive?(os_pid) end)
  end
end
