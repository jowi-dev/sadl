defmodule Sadld.Plugins do
  @moduledoc """
  Finds the `Sadld.Plugin`s a session gets: one `Sadld.Sidecar` for each
  configured opencode plugin, shared by every session in the same worktree
  (ADR-0004).

  A sidecar starts the first time a session in its worktree asks, under
  `Sadld.PluginSupervisor`, which restarts it if it crashes. It is
  registered in `Sadld.PluginRegistry` under `{plugin, worktree}`, so a
  restarted one is found under the same name.

  The plugins are the paths in the `:sadld` `:plugins` setting or, when that
  is not set, the one in the `SADL_THATCH_PLUGIN` environment variable,
  which the dev shell points at the pinned thatch package.
  """

  require Logger

  alias Sadld.Sidecar

  @doc """
  Returns the plugins for a session working in `cwd`, starting any sidecar
  not yet running. A sidecar that cannot start is logged and left out.

  Options:

    * `:plugins` - plugin paths to use instead of the configured ones
  """
  @spec for_cwd(Path.t(), keyword()) :: [Sadld.Plugin.t()]
  def for_cwd(cwd, opts \\ []) do
    case Keyword.get_lazy(opts, :plugins, &configured/0) do
      [] ->
        []

      plugins ->
        worktree = worktree(cwd)

        for plugin <- plugins,
            {:ok, ref} <- [ensure_started(plugin, worktree)],
            do: {Sidecar, ref}
    end
  end

  @doc """
  Returns the worktree `cwd` is in: its git top level, or `cwd` itself
  outside a repository.
  """
  @spec worktree(Path.t()) :: Path.t()
  def worktree(cwd) do
    cwd = Path.expand(cwd)

    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {top, 0} -> String.trim(top)
      {_error, _status} -> cwd
    end
  rescue
    # No git on the PATH.
    ErlangError -> Path.expand(cwd)
  end

  defp configured do
    case Application.get_env(:sadld, :plugins) do
      nil -> List.wrap(System.get_env("SADL_THATCH_PLUGIN"))
      plugins -> plugins
    end
  end

  defp ensure_started(plugin, worktree) do
    name = {:via, Registry, {Sadld.PluginRegistry, {plugin, worktree}}}
    spec = {Sidecar, plugin: plugin, worktree: worktree, name: name}

    case DynamicSupervisor.start_child(Sadld.PluginSupervisor, spec) do
      {:ok, _pid} ->
        {:ok, name}

      {:error, {:already_started, _pid}} ->
        {:ok, name}

      {:error, reason} ->
        Logger.error("plugin #{plugin} did not start in #{worktree}: #{inspect(reason)}")
        :error
    end
  end
end
