defmodule Sadld.SidecarTest do
  # Runs the real Bun host (server/priv/sidecar) with test/support/fake_plugin.ts.
  use ExUnit.Case, async: true

  alias Sadld.{Session, Sidecar}
  alias Sadld.Test.{StubProvider, StubTools}

  @moduletag :sidecar
  @moduletag :tmp_dir

  @fake_plugin Path.expand("../support/fake_plugin.ts", __DIR__)

  # The fake plugin imports zod; lend it the pinned thatch package's.
  setup %{tmp_dir: dir} do
    plugin = Path.join(dir, "plugin.ts")
    File.cp!(@fake_plugin, plugin)
    thatch = System.fetch_env!("SADL_THATCH_PLUGIN")
    File.ln_s!(Path.expand("../../node_modules", thatch), Path.join(dir, "node_modules"))
    worktree = Path.join(dir, "project")
    File.mkdir_p!(worktree)
    %{plugin: plugin, worktree: worktree}
  end

  defp start_sidecar(plugin, worktree) do
    start_supervised!({Sidecar, plugin: plugin, worktree: worktree}, restart: :temporary)
  end

  test "offers the plugin's tools with JSON Schema parameters", ctx do
    sidecar = start_sidecar(ctx.plugin, ctx.worktree)

    assert [echo, peek, boom] = Sidecar.tools(sidecar)
    assert %{name: "echo", description: "Echo text.", parameters: parameters} = echo

    assert %{
             "type" => "object",
             "properties" => %{"text" => %{"type" => "string"}},
             "required" => ["text"]
           } = parameters

    assert peek.name == "peek"
    assert boom.name == "boom"
  end

  test "runs a tool call in the plugin", ctx do
    sidecar = start_sidecar(ctx.plugin, ctx.worktree)
    context = %{session_id: "s_1", turn_id: "t_1", cwd: ctx.worktree}
    call = %{id: "c_1", name: "echo", args: %{"text" => "hi"}}

    assert Sidecar.run_tool(sidecar, call, context) == {:ok, "hi from s_1 in #{ctx.worktree}"}

    assert {:error, message} = Sidecar.run_tool(sidecar, %{call | args: %{"text" => 1}}, context)
    assert message =~ "text"

    assert Sidecar.run_tool(sidecar, %{call | name: "boom", args: %{}}, context) ==
             {:error, "kaboom"}
  end

  test "passes hook output through the plugin", ctx do
    sidecar = start_sidecar(ctx.plugin, ctx.worktree)
    hook = "experimental.chat.system.transform"

    assert Sidecar.hook(sidecar, hook, %{}, %{"system" => ["base"]}) ==
             %{"system" => ["base", "plugin in #{ctx.worktree}"]}

    assert Sidecar.hook(sidecar, "chat.message", %{}, %{"parts" => []}) == %{"parts" => []}
  end

  test "answers the plugin's client calls while a session uses it", ctx do
    sidecar = start_sidecar(ctx.plugin, ctx.worktree)

    {:ok, id} =
      Session.start(
        cwd: ctx.worktree,
        model: "m",
        provider: {StubProvider, respond: & &1},
        tools: {StubTools, []},
        system_prompt: "s",
        plugins: [{Sidecar, sidecar}]
      )

    # The plugin answers session.created with a noReply prompt.
    assert wait_until(fn -> Session.messages(id) != [] end)
    assert Session.messages(id) == [%{role: :user, content: "remember me", synthetic: true}]

    context = %{session_id: id, turn_id: "t_1", cwd: ctx.worktree}
    call = %{id: "c_1", name: "peek", args: %{"id" => id}}
    assert {:ok, json} = Sidecar.run_tool(sidecar, call, context)
    assert %{"data" => %{"id" => ^id, "directory" => directory}} = JSON.decode!(json)
    assert directory == ctx.worktree

    missing = %{call | args: %{"id" => "missing"}}
    assert {:ok, json} = Sidecar.run_tool(sidecar, missing, context)
    assert %{"error" => %{"code" => -32_002}} = JSON.decode!(json)
  end

  @tag capture_log: true
  test "a plugin that fails to load offers nothing and changes nothing", ctx do
    sidecar = start_sidecar(Path.join(ctx.worktree, "nope.ts"), ctx.worktree)
    call = %{id: "c_1", name: "echo", args: %{"text" => "hi"}}

    assert Sidecar.tools(sidecar) == []
    assert Sidecar.hook(sidecar, "chat.message", %{}, %{"parts" => []}) == %{"parts" => []}
    assert {:error, "plugin unavailable: " <> _reason} = Sidecar.run_tool(sidecar, call, %{})
    assert Sidecar.event(sidecar, "session.idle", %{"sessionID" => "s"}) == :ok
  end

  @tag capture_log: true
  test "stops when its Bun process dies, so its supervisor can restart it", ctx do
    sidecar = start_sidecar(ctx.plugin, ctx.worktree)
    assert [_ | _] = Sidecar.tools(sidecar)
    ref = Process.monitor(sidecar)

    :ok = :exec.kill(Sidecar.os_pid(sidecar), 9)

    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:exited, _status}}, 5_000
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> wait_more(fun, tries)
    end
  end

  defp wait_more(fun, tries) do
    Process.sleep(20)
    wait_until(fun, tries - 1)
  end
end
