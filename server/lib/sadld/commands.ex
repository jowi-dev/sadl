defmodule Sadld.Commands do
  @moduledoc """
  Slash commands written as markdown, in opencode's format, so commands
  installed for opencode (such as thatch's `/thatch/*`) work in sadl too.

  Command `name` is the file `<name>.md` under `command/` or `commands/` in
  one of the command directories: opencode's config directory, then sadl's
  (`default_dirs/0`). A later directory's command replaces an earlier one's,
  so a sadl command can override an opencode one. Nested directories give
  names with slashes: `command/thatch/compact.md` is `thatch/compact`.

  A file may open with YAML front matter between `---` lines, which is
  dropped. The rest, trimmed, is the template `expand/2` fills in.
  """

  @subdirs ["command", "commands"]

  @positional ~r/\$([1-9]\d*)/

  @doc """
  Returns the command directories: `opencode` and `sadl` in the user's
  config home.
  """
  @spec default_dirs() :: [Path.t()]
  def default_dirs do
    sadl = Sadld.config_dir()
    [Path.join(Path.dirname(sadl), "opencode"), sadl]
  end

  @doc """
  Returns the template of command `name` from `dirs`, or `:error` when there
  is no such command or it cannot be read.
  """
  @spec fetch(String.t(), [Path.t()]) :: {:ok, String.t()} | :error
  def fetch(name, dirs \\ default_dirs()) do
    with true <- valid_name?(name),
         path when is_binary(path) <- find(name, dirs),
         {:ok, contents} <- File.read(path) do
      {:ok, template(contents)}
    else
      _missing -> :error
    end
  end

  defp valid_name?(name) do
    segments = String.split(name, "/")
    Enum.all?(segments, &(&1 =~ ~r/\A[\w.-]+\z/u and &1 not in [".", ".."]))
  end

  defp find(name, dirs) do
    paths =
      for dir <- Enum.reverse(dirs), sub <- @subdirs, do: Path.join([dir, sub, name <> ".md"])

    Enum.find(paths, &File.regular?/1)
  end

  defp template(contents) do
    body =
      case Regex.run(~r/\A---\r?\n.*?\r?\n---(?:\r?\n|\z)(.*)\z/s, contents) do
        [_all, body] -> body
        nil -> contents
      end

    String.trim(body)
  end

  @doc """
  Fills in `template` with the `arguments` typed after the command, as
  opencode does: `$ARGUMENTS` becomes the whole string and `$1`, `$2`, ...
  its whitespace-separated words, the highest-numbered placeholder taking
  every word from its own on. A template with neither gets non-blank
  arguments appended after a blank line.
  """
  @spec expand(String.t(), String.t()) :: String.t()
  def expand(template, arguments) do
    words = String.split(arguments)

    last =
      @positional
      |> Regex.scan(template, capture: :all_but_first)
      |> Enum.map(fn [n] -> String.to_integer(n) end)
      |> Enum.max(fn -> 0 end)

    cond do
      last > 0 or String.contains?(template, "$ARGUMENTS") ->
        template
        |> String.replace(@positional, fn "$" <> n -> word(words, String.to_integer(n), last) end)
        |> String.replace("$ARGUMENTS", arguments)

      String.trim(arguments) == "" ->
        template

      true ->
        template <> "\n\n" <> arguments
    end
  end

  defp word(words, n, n), do: words |> Enum.drop(n - 1) |> Enum.join(" ")
  defp word(words, n, _last), do: Enum.at(words, n - 1, "")
end
