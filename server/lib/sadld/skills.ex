defmodule Sadld.Skills do
  @moduledoc """
  Finds the skills a session can load: `SKILL.md` files in the opencode
  layout, `<skills dir>/<dir>/SKILL.md`, each opening with YAML front matter
  that gives the skill's `name` and `description`. The rest of the file is
  the skill's body, the instructions the `skill` tool hands the model.

  Skills dirs are searched most specific first, and the first skill to
  claim a name wins:

    1. `.opencode/skills` in the working directory, then in each ancestor
       up to the root, nearest first;
    2. `skills` in the user's sadl config dir (`$XDG_CONFIG_HOME/sadl`);
    3. opencode's `$XDG_CONFIG_HOME/opencode/skills`, where opencode
       plugins such as thatch install theirs.

  So a project can override a user's skill, and a user's sadl skill can
  override one a plugin installed.

  Front matter is read line by line as `key: value` pairs, with optional
  single or double quotes around the value; nested and multi-line YAML
  values are not supported. Files that are unreadable, not UTF-8 text, or
  lack a `name` or `description` are skipped.
  """

  @typedoc "A discovered skill. `path` is its `SKILL.md`."
  @type t :: %{name: String.t(), description: String.t(), body: String.t(), path: Path.t()}

  @front_matter ~r/\A---\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)\s*(.*)\z/s

  @doc """
  Returns the skills dirs for a session working in `cwd`, in precedence
  order.

  Options, mostly for tests:

    * `:config_home` - the XDG config home (default `Sadld.config_home/0`)
  """
  @spec dirs(Path.t(), keyword()) :: [Path.t()]
  def dirs(cwd, opts \\ []) do
    config_home = Path.expand(Keyword.get_lazy(opts, :config_home, &Sadld.config_home/0))

    project =
      cwd
      |> Path.expand()
      |> Stream.unfold(fn
        nil -> nil
        dir -> {dir, if(Path.dirname(dir) == dir, do: nil, else: Path.dirname(dir))}
      end)
      |> Enum.map(&Path.join(&1, ".opencode/skills"))

    Enum.uniq(
      project ++
        [Path.join(config_home, "sadl/skills"), Path.join(config_home, "opencode/skills")]
    )
  end

  @doc "Returns every skill visible from `cwd`, sorted by name. Takes the options of `dirs/2`."
  @spec discover(Path.t(), keyword()) :: [t()]
  def discover(cwd, opts \\ []) do
    cwd
    |> dirs(opts)
    |> Enum.flat_map(&in_dir/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Fetches the skill called `name` visible from `cwd`. Takes the options of `dirs/2`."
  @spec fetch(Path.t(), String.t(), keyword()) :: {:ok, t()} | :error
  def fetch(cwd, name, opts \\ []) do
    case Enum.find(discover(cwd, opts), &(&1.name == name)) do
      nil -> :error
      skill -> {:ok, skill}
    end
  end

  @doc """
  Parses the text of a `SKILL.md` into its `name`, `description` and body.
  Returns `:error` when the front matter is missing or lacks either field.
  """
  @spec parse(String.t()) ::
          {:ok, %{name: String.t(), description: String.t(), body: String.t()}} | :error
  def parse(text) do
    with [_all, header, body] <- Regex.run(@front_matter, text),
         fields = fields(header),
         {:ok, name} when name != "" <- Map.fetch(fields, "name"),
         {:ok, description} when description != "" <- Map.fetch(fields, "description") do
      {:ok, %{name: name, description: description, body: body}}
    else
      _invalid -> :error
    end
  end

  defp fields(header) do
    header
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\A([A-Za-z0-9_-]+):(.*)\z/, line) do
        [_line, key, value] -> [{key, unquote_value(String.trim(value))}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  defp unquote_value(value) do
    case Regex.run(~r/\A(["'])(.*)\1\z/, value) do
      [_value, _quote, inner] -> inner
      nil -> value
    end
  end

  defp in_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&read_skill(Path.join([dir, &1, "SKILL.md"])))

      {:error, _reason} ->
        []
    end
  end

  defp read_skill(path) do
    with {:ok, text} <- File.read(path),
         true <- String.valid?(text),
         {:ok, skill} <- parse(text) do
      [Map.put(skill, :path, path)]
    else
      _invalid -> []
    end
  end
end
