defmodule Sadld.SystemPrompt do
  @moduledoc """
  Builds a session's system prompt: a short built-in part naming the tools,
  the working directory, the OS and today's date, followed by any context
  files the user keeps for the agent.

  Context files are looked up in the user's sadl config directory
  (`Sadld.config_dir/0`) and then in the working directory and each of its
  ancestors, outermost first, so the most specific instructions come last.
  Each directory contributes its `AGENTS.md`, or its `CLAUDE.md` when it
  has no `AGENTS.md`. Files that are missing, unreadable or not UTF-8 text
  are skipped.
  """

  @context_files ["AGENTS.md", "CLAUDE.md"]

  @doc """
  Returns the system prompt for a session working in `cwd`.

  Options, mostly for tests:

    * `:tools` - tool specs to describe (default `Sadld.Tools.specs/0`)
    * `:os` - OS name (default the host's, such as `"linux"`)
    * `:date` - today's date (default `Date.utc_today/0`)
    * `:config_dir` - directory of the user-global context file (default
      `Sadld.config_dir/0`)
  """
  @spec build(Path.t(), keyword()) :: String.t()
  def build(cwd, opts \\ []) do
    cwd = Path.expand(cwd)
    tools = Keyword.get_lazy(opts, :tools, &Sadld.Tools.specs/0)
    os = Keyword.get_lazy(opts, :os, &os_name/0)
    date = Keyword.get_lazy(opts, :date, &Date.utc_today/0)
    config_dir = Path.expand(Keyword.get_lazy(opts, :config_dir, &Sadld.config_dir/0))

    base = """
    You are sadl, a coding agent working in the user's project. Use the \
    tools to read, write and edit files and run commands, then report back \
    briefly.

    Tools:
    #{Enum.map_join(tools, "\n", &"- #{&1.name}: #{&1.description}")}

    Working directory: #{cwd}
    Operating system: #{os}
    Today's date: #{Date.to_iso8601(date)}
    """

    case context_files([config_dir | ancestors(cwd)]) do
      [] -> base
      files -> base <> "\n# Project context\n" <> Enum.map_join(files, &section/1)
    end
  end

  defp section({path, text}), do: "\n## #{path}\n\n#{String.trim_trailing(text)}\n"

  # `cwd` and its ancestors, root first.
  defp ancestors(cwd) do
    cwd
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while([], fn dir, acc ->
      if Path.dirname(dir) == dir, do: {:halt, [dir | acc]}, else: {:cont, [dir | acc]}
    end)
  end

  defp context_files(dirs) do
    dirs
    |> Enum.uniq()
    |> Enum.flat_map(&context_file/1)
  end

  defp context_file(dir) do
    with path when path != nil <-
           @context_files |> Enum.map(&Path.join(dir, &1)) |> Enum.find(&File.regular?/1),
         {:ok, text} <- File.read(path),
         true <- String.valid?(text) do
      [{path, text}]
    else
      _missing -> []
    end
  end

  defp os_name do
    {_family, name} = :os.type()
    Atom.to_string(name)
  end
end
