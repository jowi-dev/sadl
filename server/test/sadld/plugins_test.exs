defmodule Sadld.PluginsTest do
  use ExUnit.Case, async: true

  alias Sadld.{Plugins, Sidecar}

  @moduletag :tmp_dir

  @fake_plugin Path.expand("../support/fake_plugin.ts", __DIR__)

  test "no configured plugins means none" do
    assert Plugins.for_cwd("/tmp", plugins: []) == []
  end

  test "the worktree is the git top level, or the directory itself", %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "sub"))
    {_out, 0} = System.cmd("git", ["init", "-q", repo])

    assert Plugins.worktree(Path.join(repo, "sub")) == repo

    # tmp_dir is inside sadl's own repository.
    outside =
      Path.join(System.tmp_dir!(), "sadld-plugins-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    assert Plugins.worktree(outside) == outside
  end

  describe "with a plugin" do
    @describetag :sidecar

    setup %{tmp_dir: dir} do
      plugin = Path.join(dir, "plugin.ts")
      File.cp!(@fake_plugin, plugin)
      thatch = System.fetch_env!("SADL_THATCH_PLUGIN")
      File.ln_s!(Path.expand("../../node_modules", thatch), Path.join(dir, "node_modules"))

      worktrees =
        for name <- ["a", "b"] do
          path = Path.join(dir, name)
          File.mkdir_p!(Path.join(path, "sub"))
          {_out, 0} = System.cmd("git", ["init", "-q", path])
          path
        end

      on_exit(fn ->
        for {_id, pid, _type, _modules} <-
              DynamicSupervisor.which_children(Sadld.PluginSupervisor),
            pid != :restarting,
            do: DynamicSupervisor.terminate_child(Sadld.PluginSupervisor, pid)
      end)

      %{plugin: plugin, worktrees: worktrees}
    end

    test "starts one sidecar per worktree and shares it", %{plugin: plugin, worktrees: [a, b]} do
      assert [{Sidecar, ref}] = Plugins.for_cwd(a, plugins: [plugin])
      assert [{Sidecar, ^ref}] = Plugins.for_cwd(Path.join(a, "sub"), plugins: [plugin])
      assert [{Sidecar, other}] = Plugins.for_cwd(b, plugins: [plugin])

      assert GenServer.whereis(ref) != GenServer.whereis(other)
      assert [%{name: "echo"} | _] = Sidecar.tools(ref)
    end

    @tag capture_log: true
    test "restarts a sidecar whose Bun process dies", %{plugin: plugin, worktrees: [a, _b]} do
      [{Sidecar, ref}] = Plugins.for_cwd(a, plugins: [plugin])
      pid = GenServer.whereis(ref)
      monitor = Process.monitor(pid)

      :ok = :exec.kill(Sidecar.os_pid(ref), 9)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000

      assert wait_until(fn -> GenServer.whereis(ref) not in [nil, pid] end)
      assert [%{name: "echo"} | _] = Sidecar.tools(ref)
    end
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
