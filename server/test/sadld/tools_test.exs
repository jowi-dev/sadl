defmodule Sadld.ToolsTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol.Notification
  alias Sadld.Session
  alias Sadld.Test.StubProvider
  alias Sadld.Tools

  @moduletag :tmp_dir

  @usage %{input_tokens: 1, output_tokens: 1}

  defp call(name, args), do: %{id: "c1", name: name, args: args}

  test "specs describe read, write and edit with JSON schemas" do
    specs = Tools.specs()

    assert Enum.map(specs, & &1.name) == ["read", "write", "edit"]

    for spec <- specs do
      assert is_binary(spec.description)
      assert %{type: "object", properties: %{path: _}, required: ["path" | _]} = spec.parameters
    end
  end

  test "runs a call by tool name", %{tmp_dir: dir} do
    assert {:ok, _} = Tools.run(call("write", %{"path" => "a.txt", "content" => "hi"}), dir, [])
    assert Tools.run(call("read", %{"path" => "a.txt"}), dir, []) == {:ok, "     1\thi\n"}
  end

  test "an unknown tool is an error", %{tmp_dir: dir} do
    assert {:error, message} = Tools.run(call("fly", %{}), dir, [])
    assert message =~ "unknown tool"
    assert message =~ "fly"
  end

  test "arguments that are not an object are an error", %{tmp_dir: dir} do
    assert {:error, message} = Tools.run(call("read", ["a.txt"]), dir, [])
    assert message =~ "object"
  end

  test "a session reports tool failures to the model and keeps running", %{tmp_dir: dir} do
    respond = fn messages ->
      case List.last(messages) do
        %{role: :user} ->
          calls = [call("read", %{"path" => "missing.txt"})]
          {:ok, %{text: "", tool_calls: calls, usage: @usage}}

        %{role: :tool} ->
          {:ok, %{text: "done", tool_calls: [], usage: @usage}}
      end
    end

    {:ok, id} =
      Session.start(
        cwd: dir,
        model: "stub-model",
        provider: {StubProvider, respond: respond},
        tools: {Tools, []},
        listener: self()
      )

    {:ok, turn_id} = Session.send_message(id, "read it")

    assert_receive {:session_event, ^id,
                    %Notification{method: "tool.result", params: %{is_error: true} = result}}

    assert result.output =~ "missing.txt"

    assert_receive {:session_event, ^id,
                    %Notification{method: "turn.end", params: %{turn_id: ^turn_id} = turn_end}}

    assert turn_end.stop_reason == "completed"
    assert Process.alive?(Session.whereis(id))
  end
end
